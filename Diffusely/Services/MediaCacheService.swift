import SwiftUI
import AVKit
import Combine
import ImageIO

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
    private var activeVideoLoads = 0
    private var pendingVideoLoads: [(url: String, priority: TaskPriority)] = []

    // Maximum pixel dimension for downsampled images (screens are ~400pt wide, 3 columns = ~133pt per image, @3x = ~400px)
    // Using 600px gives some headroom for detail view and retina displays
    private let maxImageDimension: CGFloat = 600

    private init() {
        setupMemoryPressureHandling()
    }

    private func setupMemoryPressureHandling() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }
    }

    private func handleMemoryPressure() {
        // Evict oldest image entries to free memory, keeping videos (more expensive to reload)
        let imageEntries = entries.filter { entry in
            if let content = entry.value.content, case .image = content {
                return true
            }
            return false
        }

        // Sort by last access time and remove the oldest half
        let sortedEntries = imageEntries.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
        let countToRemove = max(sortedEntries.count / 2, 1)

        for (url, entry) in sortedEntries.prefix(countToRemove) {
            entry.loadingTask?.cancel()
            entry.content = nil
            entry.state = .idle
            entries.removeValue(forKey: url)
        }

        print("[MediaCache] Memory pressure: evicted \(countToRemove) image entries")
    }

    func getStatePublisher(for url: String) -> AnyPublisher<MediaLoadingState, Never> {
        getOrCreateEntry(for: url).stateSubject.eraseToAnyPublisher()
    }

    func getMediaState(for url: String) -> MediaLoadingState {
        return entries[url]?.state ?? .idle
    }

    func getImage(for url: String) -> UIImage? {
        if let entry = entries[url] {
            entry.lastAccessTime = Date()
            return entry.content?.image
        }
        return nil
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

            // Downsample the image to reduce memory usage
            guard let uiImage = downsampleImage(data: data, maxDimension: maxImageDimension) else {
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

    /// Downsamples an image to the specified maximum dimension while preserving aspect ratio.
    /// Uses ImageIO for memory-efficient decoding - the full image is never loaded into memory.
    private func downsampleImage(data: Data, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage)
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
