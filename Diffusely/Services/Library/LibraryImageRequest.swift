import Foundation
import AVFoundation
import Nuke
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Builds the Nuke `ImageRequest` for a personal-library item and owns the
/// multi-tier byte cascade behind it: a memory/disk cache hit (handled by Nuke
/// under the stable key), else CDN-first, else iCloud on-demand materialization
/// of the original. Nuke owns decode / resize / caching / concurrency; this type
/// only produces the bytes Nuke can't fetch itself.
enum LibraryImageRequest {
    /// Pixel size grid thumbnails are produced at. Requests at or below this size
    /// go through the (disk-cached) cascade; larger requests (detail view) are
    /// memory-only. Replaces the old bespoke library grid-thumbnail dimension.
    static let gridDimension: CGFloat = 600

    enum LoadError: Error { case unavailable }

    /// Dedicated session for the CDN thumbnail fallback — kept off
    /// `URLSession.civitai` (reserved for the tRPC JSON API). 10s timeout: a tiny
    /// thumbnail that hasn't responded by then is treated as dead, so the cascade
    /// falls through to the iCloud original instead of hanging.
    private static let cdnSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Stable per-item+size cache key. Any tier that succeeds caches under this
    /// one key, so a relaunch is a cache hit and never re-attempts the CDN.
    /// Folding the dimension in keeps grid (600) and detail entries distinct.
    static func cacheKey(itemID: Int, maxDimension: CGFloat) -> String {
        "library/\(itemID)@\(Int(maxDimension))"
    }

    static func request(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) -> ImageRequest {
        // Detail-size requests skip disk writes so full-res images aren't newly
        // duplicated on disk — grid thumbnails are the durable cached tier.
        let options: ImageRequest.Options = maxDimension > gridDimension ? [.disableDiskCacheWrites] : []
        return ImageRequest(
            id: cacheKey(itemID: itemID, maxDimension: maxDimension),
            data: {
                try await loadBytes(itemID: itemID, mediaFileName: mediaFileName,
                                    isVideo: isVideo, maxDimension: maxDimension)
            },
            processors: [.resize(width: maxDimension)],
            options: options
        )
    }

    /// The tier cascade. Runs only on a true Nuke cache miss.
    private static func loadBytes(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) async throws -> Data {
        let dir = try await LibraryContainer.shared.itemsDirectory()
        let originalURL = dir.appendingPathComponent(mediaFileName)

        // 1. CDN-first — a static thumbnail without downloading the original.
        if let cdn = await cdnThumbnailData(itemID: itemID, isVideo: isVideo, maxDimension: maxDimension, dir: dir) {
            return cdn
        }

        // 2. iCloud original fallback — materialize, then build a small thumbnail.
        if await LibraryFileMaterializer.isReady(url: originalURL) == false {
            try await LibraryFileMaterializer.download(url: originalURL)
            let index = await LibrarySaveService.shared.indexService
            await index?.recordAccess(itemID: itemID, status: .downloaded)
        }
        guard let image = await thumbnailImage(localURL: originalURL, isVideo: isVideo, maxDimension: maxDimension),
              let data = image.jpegData(compressionQuality: 0.8) else {
            throw LoadError.unavailable
        }
        return data
    }

    /// Fetches the derived static-thumbnail URL from the CDN. Returns the raw
    /// bytes on HTTP 200, else nil so the caller falls back to the iCloud
    /// original. If the CDN mis-serves video bytes, the registered
    /// `VideoFrameImageDecoder` extracts a frame downstream.
    private static func cdnThumbnailData(itemID: Int, isVideo: Bool, maxDimension: CGFloat, dir: URL) async -> Data? {
        guard let original = await Task.detached(priority: .userInitiated, operation: {
                  originalCDNURL(itemID: itemID, in: dir)
              }).value,
              let thumb = CivitaiThumbnailURL.thumbnail(fromOriginal: original, isVideo: isVideo, width: Int(maxDimension)),
              let url = URL(string: thumb) else { return nil }
        guard let (data, response) = try? await cdnSession.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// Builds a downsampled still from the already-local original — ImageIO for
    /// images, an `AVAssetImageGenerator` poster frame for video. Off the main
    /// actor. Shared with `LibrarySaveService` save-time cache priming.
    static func thumbnailImage(localURL: URL, isVideo: Bool, maxDimension: CGFloat) async -> PlatformImage? {
        if isVideo {
            return await extractPosterFrame(url: localURL, maxDimension: maxDimension)
        }
        return await Task.detached(priority: .userInitiated) {
            var data: Data?
            NSFileCoordinator().coordinate(readingItemAt: localURL, options: [], error: nil) { readURL in
                data = try? Data(contentsOf: readURL)
            }
            guard let data else { return nil }
            return ImageDownsampler.downsample(data: data, maxDimension: maxDimension)
        }.value
    }

    /// Extracts a poster frame from a local video file, downsampled toward
    /// `maxDimension`. Prefers a small offset (skip black opening frames), then
    /// falls back to frame 0 for very short clips.
    private static func extractPosterFrame(url: URL, maxDimension: CGFloat) async -> PlatformImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let candidateTimes: [CMTime] = [CMTime(seconds: 0.5, preferredTimescale: 600), .zero]
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

    /// Reads `originalCDNURL` from the item's local sidecar JSON. Sidecars are
    /// local and never evicted.
    private static func originalCDNURL(itemID: Int, in dir: URL) -> String? {
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
