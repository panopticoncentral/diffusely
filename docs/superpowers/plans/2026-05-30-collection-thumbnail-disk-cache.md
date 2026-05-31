# Collection Thumbnail Disk Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cache immutable Cloudflare collection thumbnails on disk so previously-viewed thumbnails load with zero network on subsequent app launches.

**Architecture:** Attach a disk-backed `URLCache` (in Application Support, 50 MB RAM / 500 MB disk) to the shared `URLSession.civitai`, plus a stateless `URLSessionDataDelegate` that force-caches `image/*` responses by injecting a long `Cache-Control: max-age` header before storage. This sits transparently beneath `MediaCacheService`; no loader logic changes. Tier stack becomes RAM (decoded) → disk (URLCache) → network.

**Tech Stack:** Swift, Foundation `URLCache` / `URLSession` / `URLSessionDataDelegate`, Swift Testing (`import Testing`).

---

## Background for the implementer

- The thumbnail URLs (`https://image.civitai.com/.../anim=false,width=450,optimized=true/<id>.jpeg`) 301-redirect to a Backblaze-B2 object whose **final 200 response has no `Cache-Control`/`Expires`** — only `Last-Modified`. Without intervention `URLCache` would revalidate on nearly every launch. The content is **immutable** (same URL ⇒ same bytes), so we force a long `Cache-Control` to get true zero-network reuse.
- The shared session is `URLSession.civitai` in `Diffusely/Services/Networking/AppURLSession.swift`. It is used for **all** app networking (image thumbnails, the JSON API, library thumbnails). The delegate must therefore only force-cache `image/*` responses and pass everything else (JSON, video, large bodies) through untouched.
- Tests use **Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. See `DiffuselyTests/LibraryThumbnailStoreTests.swift` for style.
- `CachedURLResponse` and `HTTPURLResponse` are **reference types**, so pass-through can be asserted with identity (`===`).

## File Structure

- **Create** `Diffusely/Services/Networking/ImageCacheForcingDelegate.swift` — the delegate + a pure, testable transform method. One responsibility: decide whether/how a proposed cached response is force-cached.
- **Modify** `Diffusely/Services/Networking/AppURLSession.swift` — build the `URLCache` and construct `URLSession.civitai` with the delegate.
- **Create** `DiffuselyTests/ImageCacheForcingDelegateTests.swift` — unit tests for the transform.
- **Create** `DiffuselyTests/AppURLSessionCacheTests.swift` — config wiring tests.

All test commands use this destination (adjust the simulator name if needed):

```
xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/<SuiteName>
```

---

## Task 1: `ImageCacheForcingDelegate` transform logic

**Files:**
- Create: `Diffusely/Services/Networking/ImageCacheForcingDelegate.swift`
- Test: `DiffuselyTests/ImageCacheForcingDelegateTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/ImageCacheForcingDelegateTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct ImageCacheForcingDelegateTests {
    private let sut = ImageCacheForcingDelegate()
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
        let result = sut.forcedCacheResponse(for: proposed)
        let http = result.response as! HTTPURLResponse
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=2592000")
        #expect(result.data.count == 50_000)
        #expect(result.storagePolicy == .allowed)
    }

    @Test func handlesWebpImageResponse() {
        let proposed = cachedResponse(status: 200, contentType: "image/webp", byteCount: 46_352)
        let result = sut.forcedCacheResponse(for: proposed)
        let http = result.response as! HTTPURLResponse
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=2592000")
    }

    @Test func passesThroughJSONResponseUnchanged() {
        let proposed = cachedResponse(status: 200, contentType: "application/json", byteCount: 1_000)
        let result = sut.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    @Test func passesThroughOversizedImageUnchanged() {
        let proposed = cachedResponse(status: 200, contentType: "image/jpeg", byteCount: 3 * 1024 * 1024)
        let result = sut.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    @Test func passesThroughNon200ImageUnchanged() {
        let proposed = cachedResponse(status: 404, contentType: "image/jpeg", byteCount: 100)
        let result = sut.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }

    @Test func passesThroughResponseWithNoContentType() {
        let proposed = cachedResponse(status: 200, contentType: nil, byteCount: 100)
        let result = sut.forcedCacheResponse(for: proposed)
        #expect(result === proposed)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/ImageCacheForcingDelegateTests
```
Expected: FAIL to compile — `cannot find 'ImageCacheForcingDelegate' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Services/Networking/ImageCacheForcingDelegate.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/ImageCacheForcingDelegateTests
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Networking/ImageCacheForcingDelegate.swift DiffuselyTests/ImageCacheForcingDelegateTests.swift
git commit -m "Add ImageCacheForcingDelegate to force-cache immutable CDN thumbnails"
```

---

## Task 2: Wire `URLCache` + delegate into `URLSession.civitai`

**Files:**
- Modify: `Diffusely/Services/Networking/AppURLSession.swift`
- Test: `DiffuselyTests/AppURLSessionCacheTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/AppURLSessionCacheTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct AppURLSessionCacheTests {
    @Test func civitaiSessionHasDiskBackedImageCache() {
        let cache = URLSession.civitai.configuration.urlCache
        #expect(cache != nil)
        #expect((cache?.diskCapacity ?? 0) >= 500 * 1024 * 1024)
        #expect((cache?.memoryCapacity ?? 0) >= 50 * 1024 * 1024)
    }

    @Test func civitaiSessionUsesForcingDelegate() {
        #expect(URLSession.civitai.delegate is ImageCacheForcingDelegate)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```
xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/AppURLSessionCacheTests
```
Expected: FAIL — `civitaiSessionHasDiskBackedImageCache` fails because the default config's `urlCache` disk capacity is below 500 MB, and `civitaiSessionUsesForcingDelegate` fails because the session has no delegate.

- [ ] **Step 3: Modify `AppURLSession.swift`**

Replace the entire contents of `Diffusely/Services/Networking/AppURLSession.swift` with:

```swift
import Foundation

extension URLSession {
    /// Shared session with bounded timeouts and a durable on-disk image cache
    /// for all app networking.
    ///
    /// `URLSession.shared` defaults to a `timeoutIntervalForResource` of 7 days,
    /// so a stalled connection can hang a request far longer than any retry or
    /// loading-state logic expects. Here:
    ///   - `timeoutIntervalForRequest` (20s) is reset whenever new data arrives,
    ///     so it acts as a "no progress" guard that catches a true stall fast.
    ///   - `timeoutIntervalForResource` (300s) caps total request time, generous
    ///     enough for a large full-res library download but far short of 7 days.
    ///
    /// A disk-backed `URLCache` (in Application Support, so the OS does not purge
    /// it under storage pressure) plus `ImageCacheForcingDelegate` give immutable
    /// CDN thumbnails true zero-network reuse across launches. See
    /// `ImageCacheForcingDelegate` for why force-caching is required.
    static let civitai: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        config.urlCache = makeImageURLCache()
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(
            configuration: config,
            delegate: ImageCacheForcingDelegate(),
            delegateQueue: nil
        )
    }()

    private static func makeImageURLCache() -> URLCache {
        let memoryCapacity = 50 * 1024 * 1024     // 50 MB
        let diskCapacity = 500 * 1024 * 1024      // 500 MB

        // Application Support (not Caches) so the OS will not purge the cache
        // under storage pressure — durability across launches is the point.
        // Mirrors LibraryThumbnailStore's location convention.
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) {
            let directory = appSupport.appendingPathComponent("NetworkImageCache", isDirectory: true)
            return URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: directory)
        }

        // Fallback to the default location if Application Support is unavailable.
        return URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: nil)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```
xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/AppURLSessionCacheTests
```
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full test suite to check for regressions**

Run:
```
xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: PASS (all suites). Pay attention to any networking/sync tests that depend on `URLSession.civitai` behavior.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Networking/AppURLSession.swift DiffuselyTests/AppURLSessionCacheTests.swift
git commit -m "Attach durable disk URLCache + forcing delegate to URLSession.civitai"
```

---

## Task 3: Manual verification of zero-network reuse (verification risk)

This task has **no automated test** — it confirms the one runtime assumption the design flagged: that the session-level `willCacheResponse` actually fires for tasks created via the async `data(for:)` API used in `fetchImageWithTimeout`, and that reuse is truly zero-network.

**Files:** none (temporary, reverted edits only).

- [ ] **Step 1: Add a temporary verification probe**

In `Diffusely/Services/Media/MediaCacheService.swift`, inside `fetchImageWithTimeout(_:)`, immediately after the line `request.timeoutInterval = timeout`, add:

```swift
// TEMP verification — remove after confirming.
if let cached = URLSession.civitai.configuration.urlCache?.cachedResponse(for: request),
   let http = cached.response as? HTTPURLResponse {
    print("[CacheCheck] HIT  cc=\(http.value(forHTTPHeaderField: "Cache-Control") ?? "nil")  \(url.lastPathComponent)")
} else {
    print("[CacheCheck] MISS \(url.lastPathComponent)")
}
```

- [ ] **Step 2: Build and run, then browse**

Run the app (Mac or simulator). Open a collection and let thumbnails load. Console should show a run of `[CacheCheck] MISS …` on first view.

- [ ] **Step 3: Scroll the same thumbnails again (same session)**

Scroll away and back. Expected: the same URLs now log `[CacheCheck] HIT  cc=public, max-age=2592000 …`. A HIT with our injected `Cache-Control` proves the delegate fired and stored the response.

- [ ] **Step 4: Relaunch cold and reopen the same collection**

Quit the app fully and relaunch. Open the same collection. Expected: thumbnails appear **immediately**, and the console shows `[CacheCheck] HIT …` for them — confirming durable, cross-launch, zero-network reuse.

If instead you see `MISS` on the second pass, the session-level `willCacheResponse` is not firing for `data(for:)`. Fallback: change `fetchImageWithTimeout` to use `URLSession.civitai.data(for: request, delegate: ImageCacheForcingDelegate())` (per-task delegate) and re-verify. (Do not implement the fallback unless the probe shows it is needed.)

- [ ] **Step 5: Remove the temporary probe**

Delete the `// TEMP verification` block added in Step 1. Confirm `grep -rn "CacheCheck" Diffusely` returns nothing.

- [ ] **Step 6: Build to confirm clean state**

Run:
```
xcodebuild -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit (only if the fallback in Step 4 was needed)**

If Step 4 required the per-task-delegate fallback, commit it:

```bash
git add Diffusely/Services/Media/MediaCacheService.swift
git commit -m "Use per-task forcing delegate so willCacheResponse fires for data(for:)"
```

Otherwise nothing to commit (the probe was reverted).

---

## Self-Review Notes

- **Spec coverage:** URLCache config (Task 2) ✓; App Support location (Task 2) ✓; force-caching `image/*` only with size guard (Task 1) ✓; pass-through for JSON/video/large/non-200 (Task 1 tests) ✓; 30-day TTL (Task 1) ✓; session delegate wiring (Task 2) ✓; willCacheResponse-with-`data(for:)` verification risk (Task 3) ✓; testing strategy unit + config + manual (Tasks 1–3) ✓.
- **No loader changes:** `MediaCacheService` and `fetchImageWithTimeout` are untouched except the temporary, reverted probe in Task 3.
- **Type consistency:** `forcedCacheResponse(for:)`, `maxAgeSeconds`, `maxCacheableBodyBytes`, and `makeImageURLCache()` are referenced identically across tasks.
