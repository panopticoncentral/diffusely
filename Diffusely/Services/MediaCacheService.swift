import SwiftUI
import AVKit
import Combine

enum MediaContent: Equatable {
    case image(UIImage)
    case video(AVPlayer)

    static func == (lhs: MediaContent, rhs: MediaContent) -> Bool {
        switch (lhs, rhs) {
        case (.image(let img1), .image(let img2)):
            return img1 === img2
        case (.video(let player1), .video(let player2)):
            return player1 === player2
        default:
            return false
        }
    }

    var image: UIImage? {
        if case .image(let img) = self { return img }
        return nil
    }

    var player: AVPlayer? {
        if case .video(let player) = self { return player }
        return nil
    }
}

enum MediaLoadingState: Equatable {
    case idle
    case loading
    case loaded(MediaContent)
    case failed(Error)

    static func == (lhs: MediaLoadingState, rhs: MediaLoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case (.loaded(let content1), .loaded(let content2)):
            return content1 == content2
        case (.failed(let err1), .failed(let err2)):
            return (err1 as NSError) == (err2 as NSError)
        default:
            return false
        }
    }
}

@MainActor
class MediaCacheService: ObservableObject {
    static let shared = MediaCacheService()

    private var cache: [String: MediaContent] = [:]
    private var loadingTasks: [String: Task<Void, Never>] = [:]

    @Published private(set) var mediaStates: [String: MediaLoadingState] = [:]

    private init() {}

    // MARK: - Public API

    func getMediaState(for url: String) -> MediaLoadingState {
        return mediaStates[url] ?? .idle
    }

    func getMedia(for url: String) -> MediaContent? {
        return cache[url]
    }

    func getImage(for url: String) -> UIImage? {
        return cache[url]?.image
    }

    func getPlayer(for url: String) -> AVPlayer? {
        return cache[url]?.player
    }

    func preloadMedia(urls: [String], isVideo: [Bool], priority: TaskPriority = .medium) {
        for (url, isVid) in zip(urls, isVideo) {
            let currentState = mediaStates[url]
            guard currentState == nil || currentState == .idle else {
                if case .failed = currentState {
                    loadMedia(url: url, isVideo: isVid, priority: priority)
                }
                continue
            }
            loadMedia(url: url, isVideo: isVid, priority: priority)
        }
    }

    func loadMedia(url: String, isVideo: Bool, priority: TaskPriority = .medium) {
        let currentState = mediaStates[url]
        guard currentState != .loading,
              cache[url] == nil else { return }

        loadingTasks[url]?.cancel()

        mediaStates[url] = .loading

        let task = Task(priority: priority) {
            if isVideo {
                await loadVideoAsync(url: url)
            } else {
                await loadImageAsync(url: url)
            }
        }

        loadingTasks[url] = task
    }

    func retryFailed(url: String, isVideo: Bool) {
        let currentState = mediaStates[url]
        guard case .failed = currentState else { return }
        loadMedia(url: url, isVideo: isVideo)
    }

    func clearCache() {
        // Stop all video players
        for content in cache.values {
            if case .video(let player) = content {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
        }

        cache.removeAll()
        mediaStates.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }

    // MARK: - Video-specific controls

    func pauseAllVideos() {
        for content in cache.values {
            if case .video(let player) = content {
                player.pause()
            }
        }
    }

    func playVideo(url: String) {
        guard let player = cache[url]?.player else { return }
        player.play()
    }

    func pauseVideo(url: String) {
        guard let player = cache[url]?.player else { return }
        player.pause()
    }

    // MARK: - Preloading helpers

    func preloadImages(_ images: [CivitaiImage]) {
        let urls = images.map { $0.detailURL }
        let isVideo = images.map { $0.isVideo }
        preloadMedia(urls: urls, isVideo: isVideo, priority: .utility)
    }

    // MARK: - Private loading methods

    private func loadImageAsync(url: String) async {
        guard let imageURL = URL(string: url) else {
            await MainActor.run {
                mediaStates[url] = .failed(URLError(.badURL))
                loadingTasks[url] = nil
            }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: imageURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                await MainActor.run {
                    let error = URLError(.badServerResponse)
                    mediaStates[url] = .failed(error)
                    loadingTasks[url] = nil
                }
                return
            }

            guard let uiImage = UIImage(data: data) else {
                await MainActor.run {
                    let error = URLError(.cannotDecodeContentData)
                    mediaStates[url] = .failed(error)
                    loadingTasks[url] = nil
                }
                return
            }

            await MainActor.run {
                let content = MediaContent.image(uiImage)
                cache[url] = content
                mediaStates[url] = .loaded(content)
                loadingTasks[url] = nil
            }

        } catch {
            await MainActor.run {
                mediaStates[url] = .failed(error)
                loadingTasks[url] = nil
            }
        }
    }

    private func loadVideoAsync(url: String) async {
        guard let videoURL = URL(string: url) else {
            await MainActor.run {
                mediaStates[url] = .failed(URLError(.badURL))
                loadingTasks[url] = nil
            }
            return
        }

        await MainActor.run {
            let player = AVPlayer()
            let item = AVPlayerItem(url: videoURL)
            player.replaceCurrentItem(with: item)
            player.isMuted = true

            let content = MediaContent.video(player)
            cache[url] = content

            var cancellables = Set<AnyCancellable>()

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self = self else { return }

                    switch status {
                    case .readyToPlay:
                        self.mediaStates[url] = .loaded(content)
                        self.loadingTasks[url] = nil

                    case .failed:
                        let error = item.error ?? URLError(.unknown)
                        self.mediaStates[url] = .failed(error)
                        self.loadingTasks[url] = nil
                        self.cache[url] = nil

                    case .unknown:
                        break

                    @unknown default:
                        let error = URLError(.unknown)
                        self.mediaStates[url] = .failed(error)
                        self.loadingTasks[url] = nil
                        self.cache[url] = nil
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
