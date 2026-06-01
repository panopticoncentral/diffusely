import Foundation

/// Session delegate that makes immutable CDN thumbnails durably cacheable.
///
/// Civitai's image origin (Backblaze B2) returns the final image bytes with no
/// `Cache-Control`/`Expires`, so `URLCache` would otherwise revalidate them on
/// nearly every launch. Because a given thumbnail URL always yields identical
/// bytes, we inject a long `Cache-Control` before the response is written to the
/// cache, so subsequent loads (this launch or after relaunch) are served from
/// disk with no network.
///
/// Only small `image/*` 200 responses are force-cached. JSON API responses,
/// videos, and large bodies are passed through untouched so dynamic data is
/// never cached and the cache is not bloated. Stateless, hence `@unchecked
/// Sendable`.
final class ImageCacheForcingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 30 days. Thumbnails are immutable, so a long TTL is safe; `URLCache`'s
    /// own LRU still evicts under the disk-capacity ceiling.
    static let maxAgeSeconds = 2_592_000

    /// Thumbnails are ~50 KB. This guard keeps full-res originals and any video
    /// payloads that share the session out of the image cache.
    static let maxCacheableBodyBytes = 2 * 1024 * 1024

    /// Pure transform: returns a force-cacheable copy of `proposedResponse` for
    /// small image/200 responses, otherwise returns `proposedResponse` unchanged.
    /// Factored out of the delegate callback so it can be unit-tested without a
    /// live `URLSession`/`URLSessionDataTask`.
    func forcedCacheResponse(for proposedResponse: CachedURLResponse) -> CachedURLResponse {
        guard
            let http = proposedResponse.response as? HTTPURLResponse,
            http.statusCode == 200,
            let url = http.url,
            let contentType = http.value(forHTTPHeaderField: "Content-Type"),
            contentType.lowercased().hasPrefix("image/"),
            proposedResponse.data.count <= Self.maxCacheableBodyBytes
        else {
            return proposedResponse
        }

        // Rebuild the header set, dropping any existing cache-control variants and
        // adding our own. `allHeaderFields` is `[AnyHashable: Any]`; copy only the
        // string pairs.
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            if key.lowercased() == "cache-control" { continue }
            headers[key] = value
        }
        headers["Cache-Control"] = "public, max-age=\(Self.maxAgeSeconds)"

        // Foundation exposes no API to read the original HTTP version back, and the stored
        // version is irrelevant to `URLCache` (keys on URL, re-reads headers), so a literal is fine.
        guard let rewritten = HTTPURLResponse(
            url: url,
            statusCode: http.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            return proposedResponse
        }

        return CachedURLResponse(
            response: rewritten,
            data: proposedResponse.data,
            userInfo: proposedResponse.userInfo,
            storagePolicy: .allowed
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(forcedCacheResponse(for: proposedResponse))
    }
}
