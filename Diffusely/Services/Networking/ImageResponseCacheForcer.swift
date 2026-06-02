import Foundation

/// Makes immutable CDN thumbnails durably cacheable across launches.
///
/// Civitai's image origin (Backblaze B2) returns the final image bytes with no
/// `Cache-Control`/`Expires`, so `URLCache` would otherwise revalidate them on
/// nearly every launch. Because a given thumbnail URL always yields identical
/// bytes, we rewrite a long `Cache-Control` onto small `image/*` 200 responses
/// and store them in the session's `URLCache` ourselves — so subsequent loads
/// (this launch or after relaunch) are served from disk with no network.
///
/// This is deliberately **not** a `URLSessionDataDelegate`. Attaching a
/// session-wide delegate forces every request's callbacks and async-completion
/// deliveries through a single serial delegate queue (`delegateQueue: nil`),
/// which head-of-line-blocks the feed's high-concurrency image loads and strands
/// cells on a permanent grey spinner. Storing manually after each fetch keeps the
/// durable-cache win without ever touching the session's delegate queue.
enum ImageResponseCacheForcer {
    /// 30 days. Thumbnails are immutable, so a long TTL is safe; `URLCache`'s
    /// own LRU still evicts under the disk-capacity ceiling.
    static let maxAgeSeconds = 2_592_000

    /// Thumbnails are ~50 KB. This guard keeps full-res originals and any video
    /// payloads that share the session out of the image cache.
    static let maxCacheableBodyBytes = 2 * 1024 * 1024

    /// Pure transform: returns a force-cacheable copy of `proposedResponse` for
    /// small image/200 responses, otherwise returns `proposedResponse` unchanged
    /// (the same instance, so callers can detect a pass-through with `===`).
    static func forcedCacheResponse(for proposedResponse: CachedURLResponse) -> CachedURLResponse {
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

    /// Force-caches a fetched response into `cache` under `request`, stamped with a
    /// long `Cache-Control` so a later `.useProtocolCachePolicy` load is served from
    /// disk with no network. No-ops (leaving default caching untouched) for anything
    /// the transform passes through — non-image, non-200, or oversized bodies.
    static func storeIfCacheable(
        data: Data,
        response: URLResponse,
        for request: URLRequest,
        in cache: URLCache?
    ) {
        guard let cache else { return }
        let proposed = CachedURLResponse(response: response, data: data, storagePolicy: .allowed)
        let forced = forcedCacheResponse(for: proposed)
        // The transform returns the same instance for pass-through cases; only a
        // rewritten (cacheable) response is worth storing.
        guard forced !== proposed else { return }
        cache.storeCachedResponse(forced, for: request)
    }
}
