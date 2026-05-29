import Foundation
import AVFoundation

/// Loads a personal-library media file from the iCloud container, transparently
/// triggering an on-demand download when the file has been evicted, and produces
/// either a downsampled image or an AVPlayer over the local file. Parallel to
/// `MediaCacheService` (which is remote-URL only) - shares only the ImageIO
/// downsampling helper.
@MainActor
final class LibraryMediaLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double?)   // nil = indeterminate
        case image(PlatformImage)
        case video(AVPlayer)
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.failed, .failed): return true
            case let (.downloading(a), .downloading(b)): return a == b
            case (.image, .image), (.video, .video): return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private var loadTask: Task<Void, Never>?

    func load(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) {
        // Already showing this media — nothing to do.
        switch state {
        case .image, .video: return
        default: break
        }
        // Memory-cache hit: skip the disk read + decode entirely. A cell that
        // scrolled off and back gets its decoded thumbnail back synchronously
        // here instead of re-reading the file.
        if !isVideo, let cached = LibraryImageCache.shared.image(fileName: mediaFileName, maxDimension: maxDimension) {
            state = .image(cached)
            return
        }
        // A load is already in flight; don't start a second one.
        guard loadTask == nil else { return }
        loadTask = Task { await run(itemID: itemID, mediaFileName: mediaFileName, isVideo: isVideo, maxDimension: maxDimension) }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        // A view that scrolls off (or is torn down by a grid re-layout) cancels
        // the in-flight load. Return to `.idle` unless the media already loaded,
        // so the next `onAppear` cleanly restarts it. Leaving a stranded
        // `.downloading` here — combined with the old `guard case .idle` in
        // `load()` — made thumbnails spin forever until the view was destroyed
        // and recreated (e.g. by navigating away and back).
        switch state {
        case .image, .video: break
        default: state = .idle
        }
    }

    private func run(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) async {
        guard
            let dir = try? await LibraryContainer.shared.itemsDirectory()
        else {
            // A cancellation can surface as a nil here; don't mark it failed —
            // leave it for `cancel()` to reset so a re-appear retries cleanly.
            if Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: "Library items directory unavailable")
            state = .failed
            return
        }
        let url = dir.appendingPathComponent(mediaFileName)

        do {
            try await ensureDownloaded(url: url)
        } catch {
            // A cancelled load must not strand as `.failed` (it would block the
            // `load()` retry on the next onAppear); only real errors fail.
            if error is CancellationError || Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName,
                       reason: "Download failed — \((error as NSError).localizedDescription)")
            state = .failed
            return
        }

        if Task.isCancelled { return }

        if isVideo {
            state = .video(AVPlayer(url: url))
            return
        }

        // Run the file-coordinator read + ImageIO decode off the main actor.
        // The class is @MainActor for `state` plumbing, but doing the
        // synchronous Data(contentsOf:) + downsample here would serialize
        // every visible thumbnail on the main thread and freeze the UI when
        // a Library full of items appears at once.
        let outcome: LoadOutcome = await Task.detached(priority: .userInitiated) {
            var data: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                data = try? Data(contentsOf: readURL)
            }
            if let data, let image = ImageDownsampler.downsample(data: data, maxDimension: maxDimension) {
                return .success(image)
            }
            let detail: String
            if let coordError {
                detail = "File coordination error — \(coordError.localizedDescription)"
            } else if data == nil {
                detail = "Could not read file at \(url.path)"
            } else {
                detail = "Could not decode \(data?.count ?? 0) bytes as an image"
            }
            return .failure(detail)
        }.value

        if Task.isCancelled { return }

        switch outcome {
        case .success(let image):
            LibraryImageCache.shared.insert(image, fileName: mediaFileName, maxDimension: maxDimension)
            state = .image(image)
        case .failure(let detail):
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: detail)
            state = .failed
        }
    }

    private enum LoadOutcome {
        case success(PlatformImage)
        case failure(String)
    }

    /// Logs a local-library load failure with the same `[MediaError]` tag used by
    /// `MediaCacheService`, so the cause behind the orange "failed" thumbnail is visible.
    private func logFailure(itemID: Int, mediaFileName: String, reason: String) {
        print("[MediaError] Failed to load library item \(itemID) (\(mediaFileName))")
        print("[MediaError]   \(reason)")
    }

    private func ensureDownloaded(url: URL) async throws {
        // `URL.resourceValues(forKeys:)` for the ubiquity keys can perform
        // blocking iCloud metadata lookups under a cold cache; keep them off
        // the main actor so they don't pile up there.
        let initial = await Task.detached(priority: .userInitiated) {
            Self.checkLocalReadiness(at: url)
        }.value
        if initial == .ready { return }

        state = .downloading(nil)
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // Poll until the file is current/downloaded (~2 min ceiling).
        for _ in 0..<240 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let downloaded = await Task.detached(priority: .userInitiated) {
                let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                return v?.ubiquitousItemDownloadingStatus == .current
                    || v?.ubiquitousItemDownloadingStatus == .downloaded
            }.value
            if downloaded { return }
        }
        throw URLError(.timedOut)
    }

    private enum Readiness { case ready, needsDownload }

    /// Pure helper: snapshots the on-disk + iCloud-status view of `url` so the
    /// caller can decide whether to trigger a download. Safe to invoke from
    /// any thread — touches only `FileManager.default` and `URL` resource keys.
    /// `nonisolated` so the detached task that calls it doesn't have to hop
    /// back to the main actor just to read filesystem state.
    nonisolated private static func checkLocalReadiness(at url: URL) -> Readiness {
        let fileManager = FileManager.default
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])

        // Non-ubiquitous local file that exists: ready immediately.
        if values?.isUbiquitousItem != true, fileManager.fileExists(atPath: url.path) {
            return .ready
        }

        if values?.ubiquitousItemDownloadingStatus == .current
            || values?.ubiquitousItemDownloadingStatus == .downloaded {
            return .ready
        }
        return .needsDownload
    }
}
