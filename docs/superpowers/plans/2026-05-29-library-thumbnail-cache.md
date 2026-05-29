# Persistent Library Thumbnail Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the library grid render thumbnails from a durable per-device on-disk cache so browsing never downloads full-resolution originals from iCloud.

**Architecture:** Three tiers in front of the originals — RAM (`LibraryImageCache`, existing) → disk (`LibraryThumbnailStore`, new) → generate (CDN-first via a small fetcher, falling back to the iCloud original). Thumbnails are generated for free at save time, and lazily elsewhere. Detail view is unchanged (still downloads full originals).

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`), AVFoundation, ImageIO (`ImageDownsampler`), iCloud Drive ubiquity container.

**Spec:** `docs/superpowers/specs/2026-05-29-library-thumbnail-cache-design.md`

**Note on test commands:** the `xcodebuild test` lines use `-destination 'platform=iOS Simulator,name=iPhone 16'`. If that simulator isn't installed, substitute an available one (`xcrun simctl list devices available`).

**Note on a spec deviation:** the spec proposed extracting a shared CDN helper out of `MediaCacheService`. During planning we found the library's CDN path requests a *static JPEG frame* URL, so it never needs `MediaCacheService`'s "CDN served a video instead of a frame" fallback. We therefore implement a small, focused `RemoteThumbnailFetcher` for the library and leave `MediaCacheService` untouched (lower risk to the feed, no duplicated tricky code).

---

### Task 1: `CivitaiThumbnailURL` — derive a sized thumbnail URL from `originalCDNURL`

**Files:**
- Create: `Diffusely/Services/Library/CivitaiThumbnailURL.swift`
- Test: `DiffuselyTests/CivitaiThumbnailURLTests.swift`

A stored `originalCDNURL` looks like `https://image.civitai.com/<bucket>/<uuid>/original=true/<id>.<ext>`. The thumbnail URL is the same with the transform path-segment swapped and the filename forced to `.jpeg`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct CivitaiThumbnailURLTests {
    let original = "https://image.civitai.com/abc/uuid-123/original=true/999.jpeg"
    let originalVideo = "https://image.civitai.com/abc/uuid-123/original=true/999.mp4"

    @Test func imageURLSwapsTransformAndKeepsJpeg() {
        let url = CivitaiThumbnailURL.thumbnail(fromOriginal: original, isVideo: false, width: 600)
        #expect(url == "https://image.civitai.com/abc/uuid-123/anim=false,width=600,optimized=true/999.jpeg")
    }

    @Test func videoURLRequestsStaticFrameAsJpeg() {
        let url = CivitaiThumbnailURL.thumbnail(fromOriginal: originalVideo, isVideo: true, width: 600)
        #expect(url == "https://image.civitai.com/abc/uuid-123/transcode=true,anim=false,skip=4,width=600/999.jpeg")
    }

    @Test func returnsNilForUnexpectedShape() {
        #expect(CivitaiThumbnailURL.thumbnail(fromOriginal: "https://example.com/foo.jpeg", isVideo: false, width: 600) == nil)
        #expect(CivitaiThumbnailURL.thumbnail(fromOriginal: "garbage", isVideo: false, width: 600) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/CivitaiThumbnailURLTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'CivitaiThumbnailURL' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Derives a width-limited, static-JPEG thumbnail URL on the Civitai CDN from a
/// stored library `originalCDNURL` of the form
/// `https://image.civitai.com/<bucket>/<uuid>/original=true/<id>.<ext>`.
/// Returns nil if the URL is not in that expected shape (caller falls back to
/// the iCloud original).
enum CivitaiThumbnailURL {
    static func thumbnail(fromOriginal original: String, isVideo: Bool, width: Int) -> String? {
        var components = original.components(separatedBy: "/")
        // Need at least scheme//host/uuid/transform/filename.
        guard components.count >= 5 else { return nil }
        let transformIndex = components.count - 2
        let filenameIndex = components.count - 1
        // The library only ever stores the `original=true` transform; bail if absent.
        guard components[transformIndex].contains("original=true") else { return nil }

        let id = (components[filenameIndex] as NSString).deletingPathExtension
        if isVideo {
            components[transformIndex] = "transcode=true,anim=false,skip=4,width=\(width)"
        } else {
            components[transformIndex] = "anim=false,width=\(width),optimized=true"
        }
        components[filenameIndex] = "\(id).jpeg"   // always request a static JPEG frame
        return components.joined(separator: "/")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/CivitaiThumbnailURLTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/CivitaiThumbnailURL.swift DiffuselyTests/CivitaiThumbnailURLTests.swift
git commit -m "Add CivitaiThumbnailURL: derive sized CDN thumbnail URL from original"
```

---

### Task 2: `LibraryThumbnailStore` — durable on-disk thumbnail cache

**Files:**
- Create: `Diffusely/Services/Library/LibraryThumbnailStore.swift`
- Modify: `Diffusely/Utilities/PlatformImage.swift` (add cross-platform JPEG encoding)
- Test: `DiffuselyTests/LibraryThumbnailStoreTests.swift`

- [ ] **Step 1: Add cross-platform JPEG encoding to PlatformImage.swift**

Append to `Diffusely/Utilities/PlatformImage.swift` (UIImage already has `jpegData(compressionQuality:)`; add the AppKit equivalent so both platforms share the call site):

```swift
#if canImport(AppKit)
extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import Foundation
@testable import Diffusely
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct LibraryThumbnailStoreTests {
    // A 4x4 solid-color image we can encode/decode.
    func makeImage() -> PlatformImage {
        let size = CGSize(width: 4, height: 4)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        #else
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.red.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        return img
        #endif
    }

    func makeStore() -> LibraryThumbnailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbtest-\(UUID().uuidString)", isDirectory: true)
        return LibraryThumbnailStore(directory: dir)
    }

    @Test func storeThenRetrieveRoundTrips() {
        let store = makeStore()
        #expect(store.thumbnail(itemID: 1) == nil)        // miss before store
        store.store(makeImage(), itemID: 1)
        #expect(store.thumbnail(itemID: 1) != nil)        // hit after store
    }

    @Test func removeDeletesOne() {
        let store = makeStore()
        store.store(makeImage(), itemID: 1)
        store.store(makeImage(), itemID: 2)
        store.remove(itemID: 1)
        #expect(store.thumbnail(itemID: 1) == nil)
        #expect(store.thumbnail(itemID: 2) != nil)
    }

    @Test func removeAllClearsEverything() {
        let store = makeStore()
        store.store(makeImage(), itemID: 1)
        store.store(makeImage(), itemID: 2)
        store.removeAll()
        #expect(store.thumbnail(itemID: 1) == nil)
        #expect(store.thumbnail(itemID: 2) == nil)
    }

    @Test func corruptFileReadsAsMiss() throws {
        let store = makeStore()
        try store.writeRawForTesting(Data([0x00, 0x01, 0x02]), itemID: 7)
        #expect(store.thumbnail(itemID: 7) == nil)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryThumbnailStoreTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'LibraryThumbnailStore' in scope`.

- [ ] **Step 4: Write minimal implementation**

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Durable, per-device, on-disk cache of library grid thumbnails (`<id>.jpg`).
/// Lives in Application Support (not Caches, which the OS may purge under
/// storage pressure; not iCloud, which would evict and sync them). Tiny —
/// ~100 MB for a full library — so the app never evicts it. File I/O is
/// thread-safe to call off the main actor.
final class LibraryThumbnailStore: @unchecked Sendable {
    static let shared = LibraryThumbnailStore()

    /// Pixel size grid thumbnails are generated and stored at. Requests at or
    /// below this size are served from the cache; larger requests (detail view)
    /// bypass it and load the full original.
    static let gridThumbnailDimension: CGFloat = 600

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = try! FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            self.directory = appSupport.appendingPathComponent("LibraryThumbnails", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(itemID: Int) -> URL {
        directory.appendingPathComponent("\(itemID).jpg", isDirectory: false)
    }

    func thumbnail(itemID: Int) -> PlatformImage? {
        guard let data = try? Data(contentsOf: fileURL(itemID: itemID)) else { return nil }
        return PlatformImage(data: data)   // nil if the bytes aren't a valid image
    }

    func store(_ image: PlatformImage, itemID: Int) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: fileURL(itemID: itemID), options: .atomic)
    }

    func remove(itemID: Int) {
        try? FileManager.default.removeItem(at: fileURL(itemID: itemID))
    }

    func removeAll() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Test seam: write arbitrary bytes to an item's slot to simulate corruption.
    func writeRawForTesting(_ data: Data, itemID: Int) throws {
        try data.write(to: fileURL(itemID: itemID), options: .atomic)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryThumbnailStoreTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/LibraryThumbnailStore.swift Diffusely/Utilities/PlatformImage.swift DiffuselyTests/LibraryThumbnailStoreTests.swift
git commit -m "Add LibraryThumbnailStore: durable on-disk grid thumbnail cache"
```

---

### Task 3: `RemoteThumbnailFetcher` — fetch + downsample a CDN thumbnail

**Files:**
- Create: `Diffusely/Services/Library/RemoteThumbnailFetcher.swift`
- Test: `DiffuselyTests/RemoteThumbnailFetcherTests.swift`

Uses an injectable fetch closure (matching the codebase's seam style) so tests don't hit the network. The CDN URL requests a static JPEG, so this is a plain fetch→downsample (no video-bytes handling needed).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Diffusely
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct RemoteThumbnailFetcherTests {
    func jpegBytes() -> Data {
        let size = CGSize(width: 8, height: 8)
        #if canImport(UIKit)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.8)!
        #else
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.blue.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        return img.jpegData(compressionQuality: 0.8)!
        #endif
    }

    func response(_ code: Int, _ url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    @Test func returnsImageForValidJpeg() async {
        let data = jpegBytes()
        let fetcher = RemoteThumbnailFetcher { url in (data, self.response(200, url)) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image != nil)
    }

    @Test func returnsNilOnNon200() async {
        let fetcher = RemoteThumbnailFetcher { url in (Data(), self.response(404, url)) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image == nil)
    }

    @Test func returnsNilOnThrow() async {
        let fetcher = RemoteThumbnailFetcher { _ in throw URLError(.notConnectedToInternet) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image == nil)
    }

    @Test func returnsNilForGarbageBytes() async {
        let fetcher = RemoteThumbnailFetcher { url in (Data([0x00, 0x01]), self.response(200, url)) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/RemoteThumbnailFetcherTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'RemoteThumbnailFetcher' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/RemoteThumbnailFetcherTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/RemoteThumbnailFetcher.swift DiffuselyTests/RemoteThumbnailFetcherTests.swift
git commit -m "Add RemoteThumbnailFetcher: fetch + downsample a CDN thumbnail"
```

---

### Task 4: Wire the grid loader to use the thumbnail tiers

**Files:**
- Modify: `Diffusely/Services/Library/LibraryMediaLoader.swift`

Restructure `run()` so the `.image` output path consults the disk store and the CDN before ever downloading the iCloud original. The `.player` path is unchanged. This is the core behavior change.

- [ ] **Step 1: Add a sidecar-reading helper for the CDN URL**

Add this `nonisolated` helper to `LibraryMediaLoader` (next to `checkLocalReadiness`). It reads `originalCDNURL` from the local sidecar:

```swift
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
```

- [ ] **Step 2: Replace the body of `run(...)` with output-branched logic**

Replace the current `run(...)` method (the directory resolve + `ensureDownloaded` + isVideo/decode/recordAccess body) with the following. Three paths: a grid thumbnail (store→CDN→original), a full image for detail (original only, **bypasses** the thumbnail store so 2048 px requests aren't served the 600 px thumbnail), and the player (unchanged):

```swift
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
        LibraryThumbnailStore.shared.store(image, itemID: itemID)
        LibraryImageCache.shared.insert(image, fileName: mediaFileName, maxDimension: maxDimension)
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
```

`thumbnailFromLocalOriginal` is declared `nonisolated static` (not `private`) so Task 5 can call it from `LibrarySaveService`. Then **delete the now-unused `LoadOutcome` enum** — the new code returns `PlatformImage?` directly and never uses it. Keep `ensureDownloaded`, `checkLocalReadiness`, `extractPosterFrame`, `logFailure`, and the in-memory cache fast-path in `load()`.

- [ ] **Step 3: Make the grid pass the shared dimension constant**

In `Diffusely/Views/LibraryView.swift`, the grid's `LibraryAsyncImage` currently passes `maxDimension: 600`. Change it to the single source of truth so the gate and the store agree:

```swift
                LibraryAsyncImage(
                    itemID: item.itemID,
                    mediaFileName: item.mediaFileName,
                    isVideo: item.isVideo,
                    maxDimension: LibraryThumbnailStore.gridThumbnailDimension,
                    contentMode: .fill
                )
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' -configuration Debug -quiet; echo "exit: $?"`
Expected: `exit: 0`.

- [ ] **Step 5: Manual verification**

Run from Xcode. In Settings tap "Free Up Space Now", relaunch, open Library. Expected: evicted cells fill in with thumbnails **without** the cloud-download spinner (CDN path), network activity is small thumbnail fetches (not full originals), and scrolling back to a seen cell is instant (disk + RAM cache). Confirm video cells show poster frames. Open one item in detail — it should be full-resolution (not the blurry 600 px thumbnail), confirming the detail path bypasses the store.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/LibraryMediaLoader.swift Diffusely/Views/LibraryView.swift
git commit -m "Render grid thumbnails from disk/CDN tiers instead of full originals"
```

---

### Task 5: Generate the thumbnail at save time

**Files:**
- Modify: `Diffusely/Services/Library/LibrarySaveService.swift`

When an item is saved, the original bytes are already on disk (the committed media file). Generate and store the thumbnail then — free, no extra download — so the saving device never needs to rebuild.

- [ ] **Step 1: Add thumbnail generation after a successful commit**

In `performSave(...)`, immediately after the existing successful `writer.commit(metadata:mediaTempURL:)` and the `indexService?.ingest(...)` call, add:

```swift
        // Generate the grid thumbnail now, while the original is local — free,
        // no extra download. Off the main actor (ImageIO / AVAssetImageGenerator).
        let finalMediaURL = itemsDirectory.appendingPathComponent(metadata.mediaFileName)
        let isVideo = metadata.mediaType == .video
        if let thumb = await LibraryMediaLoader.thumbnailFromLocalOriginal(
            url: finalMediaURL, isVideo: isVideo, maxDimension: LibraryThumbnailStore.gridThumbnailDimension) {
            LibraryThumbnailStore.shared.store(thumb, itemID: metadata.itemID)
        }
```

This reuses `LibraryMediaLoader.thumbnailFromLocalOriginal` from Task 4. Make that method visible to this file by removing `private` from its declaration (keep it `nonisolated static`):

```swift
    nonisolated static func thumbnailFromLocalOriginal(url: URL, isVideo: Bool, maxDimension: CGFloat) async -> PlatformImage? {
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' -configuration Debug -quiet; echo "exit: $?"`
Expected: `exit: 0`.

- [ ] **Step 3: Manual verification**

Run from Xcode. Save a new image and a new video from the feed. Then go to Library — both should show thumbnails immediately with no spinner (served from the just-written disk thumbnail), even though the in-memory cache is cold.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Services/Library/LibraryMediaLoader.swift Diffusely/Services/Library/LibrarySaveService.swift
git commit -m "Generate library thumbnail at save time from the local original"
```

---

### Task 6: Clear thumbnails on delete and reset

**Files:**
- Modify: `Diffusely/Services/Library/LibraryStore.swift`

- [ ] **Step 1: Remove the thumbnail in `remove(itemID:)`**

In `LibraryStore.remove(itemID:)`, after the existing `await indexService.remove(itemID: itemID)` line, add:

```swift
        LibraryThumbnailStore.shared.remove(itemID: itemID)
```

- [ ] **Step 2: Clear all thumbnails in `resetLibrary()`**

In `LibraryStore.resetLibrary()`, after the existing `await indexService.wipe()` line, add:

```swift
        LibraryThumbnailStore.shared.removeAll()
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' -configuration Debug -quiet; echo "exit: $?"`
Expected: `exit: 0`.

- [ ] **Step 4: Manual verification**

Run from Xcode. Delete one library item — its thumbnail file should be gone (no stale render if re-added). Then Settings → Reset Library — `LibraryThumbnails/` should be emptied.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryStore.swift
git commit -m "Clear library thumbnails on item delete and library reset"
```

---

### Task 7: Full test + regression pass

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30`
Expected: all suites pass, including the three new ones.

- [ ] **Step 2: End-to-end manual check on a large/over-limit library**

Run from Xcode. Settings → "Free Up Space Now" (evict everything), relaunch, open Library, scroll the whole library. Expected: thumbnails populate from CDN at small data cost; the on-device "Downloaded" total stays low (originals are **not** mass-downloaded just to browse); scrolling back is instant. Open one item in detail — that one downloads the full original (expected).

- [ ] **Step 3: Confirm no regression to the feed**

Run from Xcode. Browse the Images/Videos feed — confirm thumbnails and detail still load normally (we did not touch `MediaCacheService`).
