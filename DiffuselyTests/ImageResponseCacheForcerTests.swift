import Testing
import Foundation
@testable import Diffusely

@Suite struct ImageResponseCacheForcerTests {
    private let url = URL(string: "https://image.civitai.com/x/anim=false,width=450,optimized=true/1.jpeg")!

    private func cachedResponse(
        status: Int,
        contentType: String?,
        byteCount: Int
    ) -> CachedURLResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return CachedURLResponse(response: response, data: Data(count: byteCount))
    }

    @Test func stampsLongCacheControlOnSmallImageResponse() {
        let proposed = cachedResponse(status: 200, contentType: "image/jpeg", byteCount: 50_000)
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        let http = result.response as! HTTPURLResponse
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=2592000")
        #expect(result.data.count == 50_000)
        #expect(result.storagePolicy == .allowed)
    }

    @Test func handlesWebpImageResponse() {
        let proposed = cachedResponse(status: 200, contentType: "image/webp", byteCount: 46_352)
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        let http = result.response as! HTTPURLResponse
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=2592000")
    }

    @Test func preservesOtherHeadersAndReplacesExistingCacheControl() {
        let headers: [String: String] = [
            "Content-Type": "image/jpeg",
            "ETag": "\"abc123\"",
            "Cache-Control": "no-store"
        ]
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        let proposed = CachedURLResponse(response: response, data: Data(count: 50_000))
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        let http = result.response as! HTTPURLResponse
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=2592000")
        #expect(http.value(forHTTPHeaderField: "ETag") == "\"abc123\"")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    }

    @Test func passesThroughJSONResponseUnchanged() {
        let proposed = cachedResponse(status: 200, contentType: "application/json", byteCount: 1_000)
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    @Test func passesThroughOversizedImageUnchanged() {
        let proposed = cachedResponse(status: 200, contentType: "image/jpeg", byteCount: 3 * 1024 * 1024)
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    @Test func passesThroughNon200ImageUnchanged() {
        let proposed = cachedResponse(status: 404, contentType: "image/jpeg", byteCount: 100)
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    @Test func passesThroughResponseWithNoContentType() {
        let proposed = cachedResponse(status: 200, contentType: nil, byteCount: 100)
        let result = ImageResponseCacheForcer.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    // MARK: - storeIfCacheable

    private func makeCache() -> URLCache {
        // In-memory only (diskCapacity 0) so the test leaves nothing on disk.
        URLCache(memoryCapacity: 5 * 1024 * 1024, diskCapacity: 0, directory: nil)
    }

    private func httpResponse(status: Int, contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
    }

    @Test func storeIfCacheableStampsAndStoresSmallImage() {
        let cache = makeCache()
        let request = URLRequest(url: url)
        ImageResponseCacheForcer.storeIfCacheable(
            data: Data(count: 50_000),
            response: httpResponse(status: 200, contentType: "image/jpeg"),
            for: request,
            in: cache
        )
        let stored = cache.cachedResponse(for: request)
        #expect(stored != nil)
        let http = stored?.response as? HTTPURLResponse
        #expect(http?.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=2592000")
    }

    @Test func storeIfCacheableSkipsVideoResponse() {
        let cache = makeCache()
        let request = URLRequest(url: url)
        ImageResponseCacheForcer.storeIfCacheable(
            data: Data(count: 50_000),
            response: httpResponse(status: 200, contentType: "video/mp4"),
            for: request,
            in: cache
        )
        #expect(cache.cachedResponse(for: request) == nil)
    }

    @Test func storeIfCacheableSkipsOversizedImage() {
        let cache = makeCache()
        let request = URLRequest(url: url)
        ImageResponseCacheForcer.storeIfCacheable(
            data: Data(count: 3 * 1024 * 1024),
            response: httpResponse(status: 200, contentType: "image/jpeg"),
            for: request,
            in: cache
        )
        #expect(cache.cachedResponse(for: request) == nil)
    }
}
