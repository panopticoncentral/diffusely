import SwiftUI
import AVKit
import Combine

@MainActor
class VideoCacheService: ObservableObject {
    static let shared = VideoCacheService()

    private var players: [String: AVPlayer] = [:]
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    private var loadingStates: [String: VideoLoadingState] = [:]

    @Published private(set) var videoStates: [String: VideoLoadingState] = [:]

    enum VideoLoadingState: Equatable {
        case idle
        case loading
        case loaded(AVPlayer)
        case failed(Error)

        static func == (lhs: VideoLoadingState, rhs: VideoLoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading):
                return true
            case (.loaded(let player1), .loaded(let player2)):
                return player1 === player2
            case (.failed(let err1), .failed(let err2)):
                return (err1 as NSError) == (err2 as NSError)
            default:
                return false
            }
        }
    }

    private init() {}

    func getVideoState(for url: String) -> VideoLoadingState {
        return videoStates[url] ?? .idle
    }

    func getPlayer(for url: String) -> AVPlayer? {
        return players[url]
    }

    func preloadVideos(urls: [String], priority: TaskPriority = .medium) {
        for url in urls {
            let currentState = videoStates[url]
            guard currentState == nil || currentState == .idle else {
                if case .failed = currentState {
                    loadVideo(url: url, priority: priority)
                }
                continue
            }
            loadVideo(url: url, priority: priority)
        }
    }

    func loadVideo(url: String, priority: TaskPriority = .medium) {
        let currentState = videoStates[url]
        guard currentState != .loading,
              players[url] == nil else { return }

        loadingTasks[url]?.cancel()

        videoStates[url] = .loading

        let task = Task(priority: priority) {
            await loadVideoAsync(url: url)
        }

        loadingTasks[url] = task
    }

    private func loadVideoAsync(url: String) async {
        guard let videoURL = URL(string: url) else {
            await MainActor.run {
                videoStates[url] = .failed(URLError(.badURL))
                loadingTasks[url] = nil
            }
            return
        }

        print("🎬 Loading video: \(url)")
        let startTime = Date()

        await MainActor.run {
            let player = AVPlayer()
            let item = AVPlayerItem(url: videoURL)
            player.replaceCurrentItem(with: item)
            player.isMuted = true

            players[url] = player

            var cancellables = Set<AnyCancellable>()

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self = self else { return }

                    switch status {
                    case .readyToPlay:
                        let loadTime = Date().timeIntervalSince(startTime)
                        self.videoStates[url] = .loaded(player)
                        self.loadingTasks[url] = nil
                        print("✅ Video loaded: \(url) in \(String(format: "%.2f", loadTime))s")

                    case .failed:
                        let loadTime = Date().timeIntervalSince(startTime)
                        let error = item.error ?? URLError(.unknown)
                        self.videoStates[url] = .failed(error)
                        self.loadingTasks[url] = nil
                        self.players[url] = nil
                        print("❌ Video failed: \(url) - \(error.localizedDescription)")

                    case .unknown:
                        break

                    @unknown default:
                        let error = URLError(.unknown)
                        self.videoStates[url] = .failed(error)
                        self.loadingTasks[url] = nil
                        self.players[url] = nil
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
                // Don't auto-play here, let the view control playback
            }

            // Store cancellables with the player
            objc_setAssociatedObject(player, "cancellables", cancellables, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func retryFailedVideo(url: String) {
        let currentState = videoStates[url]
        guard case .failed = currentState else { return }
        loadVideo(url: url)
    }

    func clearCache() {
        // Stop all players
        players.values.forEach { player in
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        videoStates.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }

    func preloadAhead(currentIndex: Int, images: [CivitaiImage], lookahead: Int = 3) {
        let startIndex = max(0, currentIndex - 1)
        let endIndex = min(images.count - 1, currentIndex + lookahead)

        let videoUrls = Array(images[startIndex...endIndex])
            .filter { $0.isVideo }
            .map { $0.detailURL }

        preloadVideos(urls: videoUrls, priority: .utility)

        print("🎬 Preloading videos \(startIndex) to \(endIndex) (current: \(currentIndex)) - \(videoUrls.count) videos")
    }

    func pauseAll() {
        players.values.forEach { $0.pause() }
    }

    func playVideo(url: String) {
        guard let player = players[url] else { return }
        player.play()
    }

    func pauseVideo(url: String) {
        guard let player = players[url] else { return }
        player.pause()
    }
}