import SwiftUI
import AVKit
import Combine

@MainActor
class MediaCacheService: ObservableObject {
    static let shared = MediaCacheService()

    private class CacheEntry {
        var content: MediaContent?
        var loadingTask: Task<Void, Never>?
        let stateSubject: CurrentValueSubject<MediaLoadingState, Never>

        init() {
            self.stateSubject = CurrentValueSubject<MediaLoadingState, Never>(.idle)
        }

        var state: MediaLoadingState {
            get { stateSubject.value }
            set { stateSubject.send(newValue) }
        }
    }

    private var entries: [String: CacheEntry] = [:]

    private init() {}

    func getStatePublisher(for url: String) -> AnyPublisher<MediaLoadingState, Never> {
        getOrCreateEntry(for: url).stateSubject.eraseToAnyPublisher()
    }

    func getMediaState(for url: String) -> MediaLoadingState {
        return entries[url]?.state ?? .idle
    }

    func getImage(for url: String) -> UIImage? {
        return entries[url]?.content?.image
    }

    func getPlayer(for url: String) -> AVPlayer? {
        return entries[url]?.content?.player
    }

    private func getOrCreateEntry(for url: String) -> CacheEntry {
        if let entry = entries[url] {
            return entry
        }

        let entry = CacheEntry()
        entries[url] = entry
        return entry
    }

    private func updateState(for url: String, to state: MediaLoadingState) {
        let entry = getOrCreateEntry(for: url)
        entry.state = state
    }

    func loadMedia(url: String, isVideo: Bool, priority: TaskPriority = .medium) {
        let entry = getOrCreateEntry(for: url)

        // Don't reload if already cached or currently loading
        guard entry.content == nil else { return }
        guard entry.loadingTask == nil else { return }

        entry.state = .loading

        let task = Task(priority: priority) {
            if isVideo {
                await loadVideoAsync(url: url)
            } else {
                await loadImageAsync(url: url)
            }
        }

        entry.loadingTask = task
    }

    func retryFailed(url: String, isVideo: Bool) {
        let currentState = getMediaState(for: url)
        guard case .failed = currentState else { return }
        loadMedia(url: url, isVideo: isVideo)
    }

    func clearCache() {
        // Stop all video players and cancel tasks
        for entry in entries.values {
            if let content = entry.content, case .video(let player) = content {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            entry.loadingTask?.cancel()
        }

        entries.removeAll()
    }

    func preloadImages(_ images: [CivitaiImage]) {
        let urls = images.map { $0.detailURL }
        let isVideo = images.map { $0.isVideo }

        for (url, isVid) in zip(urls, isVideo) {
            let currentState = getMediaState(for: url)
            guard currentState == .idle else {
                if case .failed = currentState {
                    loadMedia(url: url, isVideo: isVid, priority: .utility)
                }
                continue
            }
            loadMedia(url: url, isVideo: isVid, priority: .utility)
        }
    }

    private func loadImageAsync(url: String) async {
        guard let imageURL = URL(string: url) else {
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if let entry = entries[url] {
                    entry.state = .failed(URLError(.badURL))
                    entry.loadingTask = nil
                }
            }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: imageURL)

            guard !Task.isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let entry = entries[url] {
                        entry.state = .failed(URLError(.badServerResponse))
                        entry.loadingTask = nil
                    }
                }
                return
            }

            guard let uiImage = UIImage(data: data) else {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let entry = entries[url] {
                        entry.state = .failed(URLError(.cannotDecodeContentData))
                        entry.loadingTask = nil
                    }
                }
                return
            }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                let content = MediaContent.image(uiImage)
                if let entry = entries[url] {
                    entry.content = content
                    entry.state = .loaded(content)
                    entry.loadingTask = nil
                }
            }

        } catch {
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if let entry = entries[url] {
                    entry.state = .failed(error)
                    entry.loadingTask = nil
                }
            }
        }
    }

    private func loadVideoAsync(url: String) async {
        guard let videoURL = URL(string: url) else {
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if let entry = entries[url] {
                    entry.state = .failed(URLError(.badURL))
                    entry.loadingTask = nil
                }
            }
            return
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard !Task.isCancelled else { return }
            let player = AVPlayer()
            let item = AVPlayerItem(url: videoURL)
            player.replaceCurrentItem(with: item)
            player.isMuted = true

            let content = MediaContent.video(player)
            if let entry = entries[url] {
                entry.content = content
            }

            var cancellables = Set<AnyCancellable>()

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self = self else { return }

                    switch status {
                    case .readyToPlay:
                        if let entry = self.entries[url] {
                            entry.state = .loaded(content)
                            entry.loadingTask = nil
                        }

                    case .failed:
                        let error = item.error ?? URLError(.unknown)
                        if let entry = self.entries[url] {
                            entry.state = .failed(error)
                            entry.loadingTask = nil
                            entry.content = nil
                        }

                    case .unknown:
                        break

                    @unknown default:
                        let error = URLError(.unknown)
                        if let entry = self.entries[url] {
                            entry.state = .failed(error)
                            entry.loadingTask = nil
                            entry.content = nil
                        }
                    }
                }
                .store(in: &cancellables)

            // Setup looping
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
            }

            // Store cancellables with the player
            objc_setAssociatedObject(player, "cancellables", cancellables, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
