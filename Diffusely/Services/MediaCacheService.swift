import SwiftUI
import AVKit
import Combine
import ImageIO
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
    private var activeVideoLoads = 0
    private var pendingVideoLoads: [(url: String, priority: TaskPriority)] = []

    // Maximum pixel dimension for downsampled images (screens are ~400pt wide, 3 columns = ~133pt per image, @3x = ~400px)
    // Using 600px gives some headroom for detail view and retina displays
    private let maxImageDimension: CGFloat = {
        #if os(macOS)
        return 1200
        #else
        return 600
        #endif
    }()

    #if !canImport(UIKit)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

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

    func getImage(for url: String) -> PlatformImage? {
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
            logMediaFailure(url: url, isVideo: false, reason: "Invalid URL")
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
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                logMediaFailure(
                    url: url,
                    isVideo: false,
                    reason: "Bad HTTP response — status \(statusCode.map(String.init) ?? "n/a"), "
                        + "content-type \(contentType(of: response) ?? "n/a"), \(data.count) bytes"
                        + bodySnippet(data: data, response: response)
                )
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let entry = entries[url] {
                        entry.state = .failed(URLError(.badServerResponse))
                        entry.loadingTask = nil
                    }
                }
                return
            }

            // Sometimes the Civitai/Cloudflare CDN ignores our `transcode=true,anim=false`
            // request and serves the raw video instead of an extracted JPEG frame. When
            // that happens, fall back to extracting a still frame locally with AVFoundation
            // so the caller still gets a usable thumbnail.
            let responseContentType = contentType(of: response) ?? ""
            if responseContentType.hasPrefix("video/") {
                let frame = await extractFrameFromVideoResponse(
                    url: url,
                    data: data,
                    contentType: responseContentType
                )
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    guard let entry = entries[url] else { return }
                    if let frame {
                        let content = MediaContent.image(frame)
                        entry.content = content
                        entry.state = .loaded(content)
                    } else {
                        entry.state = .failed(URLError(.cannotDecodeContentData))
                    }
                    entry.loadingTask = nil
                }
                return
            }

            // Downsample the image to reduce memory usage
            guard let image = downsampleImage(data: data, maxDimension: maxImageDimension) else {
                logMediaFailure(
                    url: url,
                    isVideo: false,
                    reason: "Could not decode \(data.count) bytes as an image "
                        + "(content-type \(contentType(of: response) ?? "n/a"))"
                        + bodySnippet(data: data, response: response)
                )
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
                let content = MediaContent.image(image)
                if let entry = entries[url] {
                    entry.content = content
                    entry.state = .loaded(content)
                    entry.loadingTask = nil
                }
            }

        } catch {
            if !Task.isCancelled {
                logMediaFailure(url: url, isVideo: false, reason: describe(error: error))
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if let entry = entries[url] {
                    entry.state = .failed(error)
                    entry.loadingTask = nil
                }
            }
        }
    }

    // MARK: - Failure logging

    /// Logs a media load failure with a consistent `[MediaError]` tag so the
    /// cause behind the orange "failed" thumbnail can be diagnosed from the console.
    private func logMediaFailure(url: String, isVideo: Bool, reason: String) {
        let kind = isVideo ? "video" : "image"
        print("[MediaError] Failed to load \(kind): \(url)")
        print("[MediaError]   \(reason)")
    }

    private func contentType(of response: URLResponse?) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
    }

    /// Returns a short text snippet of the response body when it looks like text
    /// (e.g. an HTML/JSON error page returned instead of image bytes). Empty otherwise.
    private func bodySnippet(data: Data, response: URLResponse?) -> String {
        let type = contentType(of: response) ?? ""
        guard type.contains("text") || type.contains("json") || type.contains("html") else { return "" }
        guard !data.isEmpty, let text = String(data: data.prefix(200), encoding: .utf8) else { return "" }
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "" : "\n[MediaError]   body: \(collapsed)"
    }

    private func describe(error: Error) -> String {
        if let urlError = error as? URLError {
            return "Network error — \(urlError.code) (\(urlError.errorCode)): \(urlError.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    // MARK: - Video → image fallback

    /// Maximum video payload we'll stage to disk for local thumbnail extraction
    /// when the CDN serves a video instead of the requested image. Larger payloads
    /// bail to a logged failure rather than wasting memory on a multi-minute upload.
    private static let maxVideoBytesForThumbnailExtraction = 50 * 1024 * 1024  // 50 MB

    /// Writes the video bytes to a temp file and uses AVAssetImageGenerator to
    /// extract a single still frame, downsampled to `maxImageDimension`. Returns
    /// nil on any failure; failures are logged via `logMediaFailure`.
    private func extractFrameFromVideoResponse(url: String, data: Data, contentType: String) async -> PlatformImage? {
        guard data.count <= Self.maxVideoBytesForThumbnailExtraction else {
            logMediaFailure(
                url: url,
                isVideo: false,
                reason: "CDN served \(contentType) (\(data.count) bytes) instead of an image; "
                    + "exceeds \(Self.maxVideoBytesForThumbnailExtraction)-byte local-extraction cap"
            )
            return nil
        }

        let ext: String
        if contentType.contains("quicktime") {
            ext = "mov"
        } else if contentType.contains("webm") {
            ext = "webm"
        } else {
            ext = "mp4"
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-thumb-\(UUID().uuidString)")
            .appendingPathExtension(ext)

        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            logMediaFailure(
                url: url,
                isVideo: false,
                reason: "Failed to stage video for thumbnail extraction: \(error.localizedDescription)"
            )
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let asset = AVURLAsset(url: tempURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxImageDimension, height: maxImageDimension)
        // Frame-accurate seeking fails on some codecs; let AVFoundation snap to the
        // nearest decodable frame in either direction.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // Prefer a small positive offset (skip black opening frames), then fall
        // back to frame 0 for very short or single-frame videos.
        let candidateTimes: [CMTime] = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            .zero
        ]

        for time in candidateTimes {
            do {
                let result = try await generator.image(at: time)
                let cgImage = result.image
                #if canImport(UIKit)
                return PlatformImage(cgImage: cgImage)
                #elseif canImport(AppKit)
                return PlatformImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                #endif
            } catch {
                continue
            }
        }

        logMediaFailure(
            url: url,
            isVideo: false,
            reason: "AVAssetImageGenerator could not extract a frame from \(data.count)-byte \(contentType)"
        )
        return nil
    }

    private func downsampleImage(data: Data, maxDimension: CGFloat) -> PlatformImage? {
        ImageDownsampler.downsample(data: data, maxDimension: maxDimension)
    }

    private func loadVideoAsync(url: String) async {
        guard let videoURL = URL(string: url) else {
            logMediaFailure(url: url, isVideo: true, reason: "Invalid URL")
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
                        self.logMediaFailure(url: url, isVideo: true, reason: self.describe(error: error))
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
                        self.logMediaFailure(url: url, isVideo: true, reason: "Unknown player item status")
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
