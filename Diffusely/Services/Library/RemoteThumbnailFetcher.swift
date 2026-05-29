import Foundation
import CoreGraphics

/// Fetches a Civitai CDN thumbnail URL and downsamples it. The URL is expected
/// to request a static JPEG (constructed by `CivitaiThumbnailURL`), so there is
/// no video-frame handling here — unlike the feed's `MediaCacheService`, the
/// library's thumbnail URLs never return raw video bytes. Returns nil on any
/// failure so the caller can fall back to the iCloud original.
struct RemoteThumbnailFetcher {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    let fetch: Fetch

    init(fetch: @escaping Fetch = { try await URLSession.civitai.data(from: $0) }) {
        self.fetch = fetch
    }

    func image(from urlString: String, maxDimension: CGFloat) async -> PlatformImage? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await fetch(url) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return ImageDownsampler.downsample(data: data, maxDimension: maxDimension)
    }
}
