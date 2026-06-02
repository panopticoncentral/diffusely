import Foundation
import Nuke

/// Configures and installs the app-wide Nuke `ImagePipeline`. One pipeline owns
/// all remote still-image loading: its own bounded-timeout `URLSession`, a durable
/// on-disk `DataCache` (cross-launch reuse, no dependence on origin Cache-Control),
/// an in-memory `ImageCache`, and the registered `VideoFrameImageDecoder` so a
/// poster URL that returns video bytes still yields a still frame.
enum AppImagePipeline {
    /// Max pixel dimension for downsampled grid/detail thumbnails. Matches the old
    /// `MediaCacheService.maxImageDimension`. Applied per-request by callers.
    static var maxDimension: CGFloat {
        #if os(macOS)
        return 1200
        #else
        return 600
        #endif
    }

    /// Idempotent: safe to call more than once (tests call it directly).
    static func configure() {
        VideoFrameImageDecoder.registerOnce()

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 20
        sessionConfig.timeoutIntervalForResource = 300
        // Nuke's DataCache is the single on-disk cache; disable the URLSession one
        // so bytes aren't cached twice.
        sessionConfig.urlCache = nil

        var config = ImagePipeline.Configuration()
        config.dataLoader = DataLoader(configuration: sessionConfig)
        config.dataCache = try? DataCache(name: "com.achatessoftware.diffusely.images")
        config.imageCache = ImageCache.shared

        ImagePipeline.shared = ImagePipeline(configuration: config)
    }
}
