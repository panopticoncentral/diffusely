import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

    /// What the caller wants produced. The grid (`LibraryAsyncImage`) wants a
    /// still image even for videos (a poster frame); the detail player
    /// (`LibraryVideoPlayer`) wants a live `AVPlayer`.
    enum Output { case image, player }

    @Published private(set) var state: State = .idle

    private var loadTask: Task<Void, Never>?

    func load(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat, as output: Output = .image) {
        // Already showing this media — nothing to do.
        switch state {
        case .image, .video: return
        default: break
        }
        // Memory-cache hit: skip the disk read + decode entirely. A cell that
        // scrolled off and back gets its decoded thumbnail back synchronously
        // here instead of re-reading the file. Applies to video poster frames
        // too, but not the `.player` path (which wants a live AVPlayer).
        if output == .image, let cached = LibraryImageCache.shared.image(fileName: mediaFileName, maxDimension: maxDimension) {
            state = .image(cached)
            return
        }
        // A load is already in flight; don't start a second one.
        guard loadTask == nil else { return }
        loadTask = Task { await run(itemID: itemID, mediaFileName: mediaFileName, isVideo: isVideo, maxDimension: maxDimension, output: output) }
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

    private func run(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat, output: Output) async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else {
            if Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: "Library items directory unavailable")
            state = .failed
            return
        }
        let url = dir.appendingPathComponent(mediaFileName)

        switch output {
        case .player:
            await runVideoPlayer(itemID: itemID, mediaFileName: mediaFileName, url: url)
        case .image where maxDimension <= LibraryThumbnailStore.gridThumbnailDimension:
            await runGridThumbnail(itemID: itemID, mediaFileName: mediaFileName, isVideo: isVideo,
                                   maxDimension: maxDimension, dir: dir, originalURL: url)
        case .image:
            await runFullImage(itemID: itemID, mediaFileName: mediaFileName, isVideo: isVideo,
                               maxDimension: maxDimension, originalURL: url)
        }
    }

    /// Grid path: disk thumbnail → CDN → iCloud original. Never downloads the
    /// full original unless both the disk cache and the CDN fail.
    private func runGridThumbnail(itemID: Int, mediaFileName: String, isVideo: Bool,
                                  maxDimension: CGFloat, dir: URL, originalURL: URL) async {
        // 1. Disk thumbnail hit — no download.
        if let cached = await Task.detached(priority: .userInitiated, operation: {
            LibraryThumbnailStore.shared.thumbnail(itemID: itemID)
        }).value {
            if Task.isCancelled { return }
            LibraryImageCache.shared.insert(cached, fileName: mediaFileName, maxDimension: maxDimension)
            state = .image(cached)
            return
        }

        // 2. CDN-first — fetch a static thumbnail without downloading the original.
        let cdnImage = await Task.detached(priority: .userInitiated, operation: { () -> PlatformImage? in
            guard let original = Self.originalCDNURL(itemID: itemID, in: dir),
                  let thumbURL = CivitaiThumbnailURL.thumbnail(fromOriginal: original, isVideo: isVideo, width: Int(maxDimension))
            else { return nil }
            return await RemoteThumbnailFetcher().image(from: thumbURL, maxDimension: maxDimension)
        }).value
        if Task.isCancelled { return }
        if let cdnImage {
            persistThumbnail(cdnImage, itemID: itemID, mediaFileName: mediaFileName, maxDimension: maxDimension)
            state = .image(cdnImage)
            return
        }

        // 3. Fallback: download the iCloud original and build the thumbnail from it.
        let didDownload: Bool
        do {
            didDownload = try await ensureDownloaded(url: originalURL)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName,
                       reason: "Download failed — \((error as NSError).localizedDescription)")
            state = .failed
            return
        }
        if Task.isCancelled { return }
        if didDownload {
            await LibrarySaveService.shared.indexService?.recordAccess(itemID: itemID, status: .downloaded)
        }

        let image = await Self.thumbnailFromLocalOriginal(url: originalURL, isVideo: isVideo, maxDimension: maxDimension)
        if Task.isCancelled { return }
        if let image {
            persistThumbnail(image, itemID: itemID, mediaFileName: mediaFileName, maxDimension: maxDimension)
            state = .image(image)
        } else {
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: "Could not build a thumbnail from the original")
            state = .failed
        }
    }

    /// Detail path: full-resolution image. Downloads the original and decodes at
    /// the requested (large) size. Deliberately does NOT touch the grid
    /// thumbnail store — that holds only 600 px thumbnails. RAM-cached by
    /// dimension, as before.
    private func runFullImage(itemID: Int, mediaFileName: String, isVideo: Bool,
                              maxDimension: CGFloat, originalURL: URL) async {
        let didDownload: Bool
        do {
            didDownload = try await ensureDownloaded(url: originalURL)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName,
                       reason: "Download failed — \((error as NSError).localizedDescription)")
            state = .failed
            return
        }
        if Task.isCancelled { return }
        if didDownload {
            await LibrarySaveService.shared.indexService?.recordAccess(itemID: itemID, status: .downloaded)
        }

        let image = await Self.thumbnailFromLocalOriginal(url: originalURL, isVideo: isVideo, maxDimension: maxDimension)
        if Task.isCancelled { return }
        if let image {
            LibraryImageCache.shared.insert(image, fileName: mediaFileName, maxDimension: maxDimension)
            state = .image(image)
        } else {
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: "Could not decode the original")
            state = .failed
        }
    }

    /// Player path: unchanged — download the original and hand back an AVPlayer.
    private func runVideoPlayer(itemID: Int, mediaFileName: String, url: URL) async {
        do {
            _ = try await ensureDownloaded(url: url)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName,
                       reason: "Download failed — \((error as NSError).localizedDescription)")
            state = .failed
            return
        }
        if Task.isCancelled { return }
        state = .video(AVPlayer(url: url))
    }

    private func persistThumbnail(_ image: PlatformImage, itemID: Int, mediaFileName: String, maxDimension: CGFloat) {
        // RAM insert is cheap; do it on the main actor so the next appearance
        // hits instantly. The disk write (JPEG encode + file I/O) is expensive —
        // run it off the main actor so encoding hundreds of thumbnails during a
        // scroll doesn't stutter the UI.
        LibraryImageCache.shared.insert(image, fileName: mediaFileName, maxDimension: maxDimension)
        Task.detached(priority: .utility) {
            LibraryThumbnailStore.shared.store(image, itemID: itemID)
        }
    }

    /// Builds a thumbnail from the already-local original: ImageIO downsample for
    /// images, AVAssetImageGenerator poster frame for videos. Off the main actor.
    nonisolated static func thumbnailFromLocalOriginal(url: URL, isVideo: Bool, maxDimension: CGFloat) async -> PlatformImage? {
        if isVideo {
            return await extractPosterFrame(path: url.path, maxDimension: maxDimension)
        }
        return await Task.detached(priority: .userInitiated) {
            var data: Data?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { readURL in
                data = try? Data(contentsOf: readURL)
            }
            guard let data else { return nil }
            return ImageDownsampler.downsample(data: data, maxDimension: maxDimension)
        }.value
    }

    /// Extracts a poster frame from a local video file, downsampled toward
    /// `maxDimension`. Mirrors `MediaCacheService`'s frame fallback but skips
    /// the temp-file staging since library media is already a local file URL.
    /// `nonisolated` so the AVFoundation work stays off the main actor.
    nonisolated private static func extractPosterFrame(path: String, maxDimension: CGFloat) async -> PlatformImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        // Frame-accurate seeking fails on some codecs; let AVFoundation snap to
        // the nearest decodable frame. Prefer a small offset (skip black opening
        // frames), then fall back to frame 0 for very short clips.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let candidateTimes: [CMTime] = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            .zero
        ]
        for time in candidateTimes {
            guard let cgImage = try? await generator.image(at: time).image else { continue }
            #if canImport(UIKit)
            return PlatformImage(cgImage: cgImage)
            #elseif canImport(AppKit)
            return PlatformImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #endif
        }
        return nil
    }

    /// Logs a local-library load failure with the same `[MediaError]` tag used by
    /// `MediaCacheService`, so the cause behind the orange "failed" thumbnail is visible.
    private func logFailure(itemID: Int, mediaFileName: String, reason: String) {
        print("[MediaError] Failed to load library item \(itemID) (\(mediaFileName))")
        print("[MediaError]   \(reason)")
    }

    /// Returns `true` if it had to materialize the file (it was evicted),
    /// `false` if it was already local.
    private func ensureDownloaded(url: URL) async throws -> Bool {
        // `URL.resourceValues(forKeys:)` for the ubiquity keys can perform
        // blocking iCloud metadata lookups under a cold cache; keep them off
        // the main actor so they don't pile up there.
        let initial = await Task.detached(priority: .userInitiated) {
            Self.checkLocalReadiness(at: url)
        }.value
        if initial == .ready { return false }

        state = .downloading(nil)
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // Poll until the file is current/downloaded (~2 min ceiling).
        let path = url.path
        for _ in 0..<240 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let downloaded = await Task.detached(priority: .userInitiated) {
                // Read through a freshly-constructed URL each iteration. `URL`
                // caches resource values on its backing object, so reusing one
                // `url` here returns the status captured on the first read
                // (.notDownloaded) forever — the poll would never observe the
                // download completing, leaving the thumbnail spinning until the
                // 2-minute timeout even though the file had already arrived. A
                // fresh URL has no cache and reports the true current status.
                let probe = URL(fileURLWithPath: path)
                let status = (try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
                return status == .current || status == .downloaded
            }.value
            if downloaded { return true }
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

    /// Reads `originalCDNURL` from the item's local sidecar JSON. `nonisolated`
    /// so it runs off the main actor; sidecars are local and never evicted.
    nonisolated private static func originalCDNURL(itemID: Int, in dir: URL) -> String? {
        let jsonURL = dir.appendingPathComponent("\(itemID).json")
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: jsonURL, options: [], error: nil) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data,
              let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        else { return nil }
        return meta.originalCDNURL
    }
}
