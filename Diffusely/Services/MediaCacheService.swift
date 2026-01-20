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

    // Limit concurrent video loads to prevent network connection exhaustion
    private let maxConcurrentVideoLoads = 3
    private var activeVideoLoads = 0
    private var pendingVideoLoads: [(url: String, priority: TaskPriority)] = []

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

        if isVideo {
            // Check if already in pending queue
            if pendingVideoLoads.contains(where: { $0.url == url }) {
                return
            }

            // Throttle video loads
            if activeVideoLoads >= maxConcurrentVideoLoads {
                pendingVideoLoads.append((url: url, priority: priority))
                return
            }

            activeVideoLoads += 1

            let task = Task(priority: priority) {
                await loadVideoAsync(url: url)
                await videoLoadCompleted()
            }
            entry.loadingTask = task
        } else {
            let task = Task(priority: priority) {
                await loadImageAsync(url: url)
            }
            entry.loadingTask = task
        }
    }

    private func videoLoadCompleted() {
        activeVideoLoads -= 1

        // Start next pending video if any
        if let next = pendingVideoLoads.first {
            pendingVideoLoads.removeFirst()
            let entry = getOrCreateEntry(for: next.url)

            // Only load if still needed (not cancelled/already loaded)
            guard entry.content == nil, entry.loadingTask == nil else {
                // Try next one
                videoLoadCompleted()
                return
            }

            activeVideoLoads += 1

            let task = Task(priority: next.priority) {
                await loadVideoAsync(url: next.url)
                await videoLoadCompleted()
            }
            entry.loadingTask = task
        }
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
        pendingVideoLoads.removeAll()
        activeVideoLoads = 0
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
            if let entry = entries[url] {
                entry.state = .failed(URLError(.badURL))
                entry.loadingTask = nil
            }
            return
        }

        guard !Task.isCancelled else { return }

        // Use withCheckedContinuation to wait for video to be ready or fail
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let player = AVPlayer()
            let item = AVPlayerItem(url: videoURL)
            player.replaceCurrentItem(with: item)
            player.isMuted = true

            let content = MediaContent.video(player)
            if let entry = self.entries[url] {
                entry.content = content
            }

            var cancellables = Set<AnyCancellable>()
            var hasResumed = false

            // Monitor player item status
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
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume()
                        }

                    case .failed:
                        let error = item.error ?? URLError(.unknown)
                        print("[VideoError] Failed to load: \(url)")
                        print("[VideoError] \(error.localizedDescription)")
                        if let entry = self.entries[url] {
                            entry.state = .failed(error)
                            entry.loadingTask = nil
                            entry.content = nil
                        }
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume()
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
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume()
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
