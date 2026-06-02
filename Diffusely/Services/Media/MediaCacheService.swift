import SwiftUI
import AVKit
import Combine
import Nuke
#if canImport(UIKit)
import UIKit
#endif

@MainActor
class MediaCacheService: ObservableObject {
    static let shared = MediaCacheService()

    private class CacheEntry {
        var content: MediaContent?
        var loadingTask: Task<Void, Never>?
        let stateSubject: CurrentValueSubject<MediaLoadingState, Never>
        var lastAccessTime: Date = Date()

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

    // A player item that never reaches .readyToPlay or .failed (e.g. a stalled
    // connection sitting at .unknown) would otherwise leave its load task
    // suspended forever and permanently consume one of the concurrency slots
    // above. Fail the load after this interval so the slot is released.
    private static let videoLoadTimeout: TimeInterval = 30
    private var activeVideoLoads = 0
    private var pendingVideoLoads: [(url: String, priority: TaskPriority)] = []

    #if !canImport(UIKit)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    private lazy var imagePrefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .diskCache   // warm the durable cache without holding decoded images in memory
    )

    private init() {
        setupMemoryPressureHandling()
    }

    private func setupMemoryPressureHandling() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }
        #else
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    private func handleMemoryPressure() {
        // Images live in Nuke's ImageCache, which clears itself on memory
        // warnings automatically. This service now only holds video players,
        // which are intentionally retained (expensive to recreate) — matching
        // the prior "keep videos" policy. Nothing to evict here.
    }

    func getStatePublisher(for url: String) -> AnyPublisher<MediaLoadingState, Never> {
        getOrCreateEntry(for: url).stateSubject.eraseToAnyPublisher()
    }

    func getMediaState(for url: String) -> MediaLoadingState {
        return entries[url]?.state ?? .idle
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

    func loadMedia(url: String, isVideo: Bool, priority: TaskPriority = .medium) {
        // Images are handled by the Nuke pipeline (see CachedAsyncImage). This
        // service is video-only; ignore any non-video request defensively.
        guard isVideo else { return }

        let entry = getOrCreateEntry(for: url)
        guard entry.content == nil else { return }
        guard entry.loadingTask == nil else { return }
        if pendingVideoLoads.contains(where: { $0.url == url }) { return }

        entry.state = .loading
        if activeVideoLoads >= maxConcurrentVideoLoads {
            pendingVideoLoads.append((url: url, priority: priority))
            return
        }
        activeVideoLoads += 1
        let task = Task(priority: priority) {
            await loadVideoAsync(url: url)
            videoLoadCompleted()
        }
        entry.loadingTask = task
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
                videoLoadCompleted()
            }
            entry.loadingTask = task
        }
    }

    /// Cancels an in-flight load for `url` when its view scrolls off-screen, so we
    /// stop fetching media the user has already scrolled past while media that's
    /// actually on screen waits in the connection queue. Anything already loaded
    /// is left cached; a reappearing view re-triggers the load via `onAppear`.
    func cancelLoad(url: String) {
        guard let entry = entries[url] else { return }
        // `content` is non-nil once an image is decoded or a video's player has
        // been attached (even before it's ready), so this guard naturally keeps
        // loaded images and in-flight video loads — the latter can't be resumed
        // by cancellation anyway and are bounded by `videoLoadTimeout`.
        guard entry.content == nil else { return }

        // Still waiting in a throttle queue (never started) — just drop it.
        if let queueIndex = pendingVideoLoads.firstIndex(where: { $0.url == url }) {
            pendingVideoLoads.remove(at: queueIndex)
            entry.state = .idle
            return
        }

        // Otherwise it's an in-flight fetch; cancelling the task cancels the
        // underlying URLSession data task.
        if let task = entry.loadingTask {
            task.cancel()
            entry.loadingTask = nil
            entry.state = .idle
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
        var imageRequests: [ImageRequest] = []
        for image in images {
            let url = image.detailURL
            if image.isVideo {
                let currentState = getMediaState(for: url)
                if currentState == .idle {
                    loadMedia(url: url, isVideo: true, priority: .utility)
                } else if case .failed = currentState {
                    loadMedia(url: url, isVideo: true, priority: .utility)
                }
            } else if let u = URL(string: url) {
                imageRequests.append(ImageRequest(url: u, processors: [.resize(width: AppImagePipeline.maxDimension)]))
            }
        }
        if !imageRequests.isEmpty {
            imagePrefetcher.startPrefetching(with: imageRequests)
        }
    }

    // MARK: - Failure logging

    /// Logs a media load failure with a consistent `[MediaError]` tag so the
    /// cause behind the orange "failed" thumbnail can be diagnosed from the console.
    private func logMediaFailure(url: String, reason: String) {
        print("[MediaError] Failed to load video: \(url)")
        print("[MediaError]   \(reason)")
    }

    private func describe(error: Error) -> String {
        if let urlError = error as? URLError {
            return "Network error — \(urlError.code) (\(urlError.errorCode)): \(urlError.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    private func loadVideoAsync(url: String) async {
        guard let videoURL = URL(string: url) else {
            logMediaFailure(url: url, reason: "Invalid URL")
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

            // Fired if the item never resolves to ready/failed within the timeout.
            // Everything here runs on the main queue, matching the sink's queue,
            // so `hasResumed` is mutated from a single context without a race.
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard !hasResumed else { return }
                hasResumed = true
                self?.logMediaFailure(url: url, reason: "Timed out waiting for video to become ready")
                if let entry = self?.entries[url] {
                    entry.state = .failed(URLError(.timedOut))
                    entry.loadingTask = nil
                    entry.content = nil
                }
                player.replaceCurrentItem(with: nil)
                continuation.resume()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.videoLoadTimeout, execute: timeoutWork)

            // Monitor player item status
            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self = self else { return }
                    // Ignore any late status changes once the load has resolved
                    // (including via timeout) so we never flip a failed/torn-down
                    // entry back to loaded.
                    guard !hasResumed else { return }

                    switch status {
                    case .readyToPlay:
                        hasResumed = true
                        timeoutWork.cancel()
                        if let entry = self.entries[url] {
                            entry.state = .loaded(content)
                            entry.loadingTask = nil
                        }
                        continuation.resume()

                    case .failed:
                        hasResumed = true
                        timeoutWork.cancel()
                        let error = item.error ?? URLError(.unknown)
                        self.logMediaFailure(url: url, reason: self.describe(error: error))
                        if let entry = self.entries[url] {
                            entry.state = .failed(error)
                            entry.loadingTask = nil
                            entry.content = nil
                        }
                        continuation.resume()

                    case .unknown:
                        // Still resolving — keep waiting; the timeout guards a
                        // permanent stall here.
                        break

                    @unknown default:
                        hasResumed = true
                        timeoutWork.cancel()
                        let error = URLError(.unknown)
                        self.logMediaFailure(url: url, reason: "Unknown player item status")
                        if let entry = self.entries[url] {
                            entry.state = .failed(error)
                            entry.loadingTask = nil
                            entry.content = nil
                        }
                        continuation.resume()
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
