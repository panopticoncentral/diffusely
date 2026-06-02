import Foundation
import CoreGraphics

/// Fetches a Civitai CDN thumbnail URL and downsamples it. The URL is expected
/// to request a static JPEG (constructed by `CivitaiThumbnailURL`), so there is
/// no video-frame handling here — unlike the feed's `MediaCacheService`, the
/// library's thumbnail URLs never return raw video bytes. Returns nil on any
/// failure so the caller can fall back to the iCloud original.
struct RemoteThumbnailFetcher {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    /// Thumbnails are tiny, so a CDN URL that hasn't responded in this many
    /// seconds is treated as dead — the caller then falls back to the iCloud
    /// original / poster frame instead of hanging on URLSession's 60s default.
    /// (Some video transcode URLs never return.)
    static let timeout: TimeInterval = 10

    let fetch: Fetch

    init(fetch: @escaping Fetch = { url in
        let request = URLRequest(url: url, timeoutInterval: RemoteThumbnailFetcher.timeout)
        let (data, response) = try await URLSession.civitai.data(for: request)
        // Force-cache the immutable thumbnail for zero-network reuse next launch.
        ImageResponseCacheForcer.storeIfCacheable(
            data: data,
            response: response,
            for: URLRequest(url: url),
            in: URLSession.civitai.configuration.urlCache
        )
        return (data, response)
    }) {
        self.fetch = fetch
    }

    func image(from urlString: String, maxDimension: CGFloat) async -> PlatformImage? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await fetch(url) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return ImageDownsampler.downsample(data: data, maxDimension: maxDimension)
    }
}
