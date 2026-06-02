# Nuke Library Image Migration (Plan 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route the personal-Library image path through the shared Nuke pipeline, retiring `RemoteThumbnailFetcher`, `LibraryThumbnailStore`, and `LibraryImageCache`, while keeping iCloud on-demand materialization (which Nuke can't do) on our side.

**Architecture:** `LibraryAsyncImage` is reimplemented over NukeUI `LazyImage`, like the already-merged `CachedAsyncImage`. A new `LibraryImageRequest` factory builds a Nuke `ImageRequest(id:data:)` with a stable per-item+size cache key; its `@Sendable` data closure runs the existing tier cascade (CDN-first → iCloud original) only on a true cache miss and returns small JPEG bytes. A new `LibraryFileMaterializer` holds the iCloud download/poll logic, shared with the surviving video-player path. Nuke owns decode, resize, two-tier caching, bounded concurrency, prioritization, and off-screen cancellation.

**Tech Stack:** Swift, SwiftUI, Nuke 12.9.0 + NukeUI, AVFoundation, ImageIO, Swift Testing (`@Suite`/`@Test`/`#expect`). Build/test via `xcodebuild` against the `Diffusely` scheme on an iOS Simulator.

**Design spec:** `docs/superpowers/specs/2026-06-02-nuke-library-image-migration-design.md`

**Conventions used in every test/build step below:**
- Test a single suite: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/<SuiteName>`
- Full build: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17'`
- Each task ends compiling and committed. New types are added before their consumers are rewired, and the three retired types are deleted last, so the project builds at every commit.

---

## File Structure

**Create:**
- `Diffusely/Services/Library/LibraryFileMaterializer.swift` — nonisolated iCloud download/readiness orchestration (extracted from `LibraryMediaLoader`).
- `Diffusely/Services/Library/LibraryImageRequest.swift` — Nuke `ImageRequest` factory + the CDN→iCloud byte cascade + local-file thumbnail builders.
- `DiffuselyTests/LibraryFileMaterializerTests.swift`
- `DiffuselyTests/LibraryImageRequestTests.swift`

**Modify:**
- `Diffusely/Views/LibraryAsyncImage.swift` — reimplement over `LazyImage`.
- `Diffusely/Views/LibraryView.swift:190` — use `LibraryImageRequest.gridDimension`.
- `Diffusely/Services/Library/LibrarySaveService.swift:~270` — prime Nuke's cache instead of `LibraryThumbnailStore`.
- `Diffusely/Services/Library/LibraryStore.swift:128,144` — drop thumbnail eviction calls.
- `Diffusely/Services/Library/LibraryMediaLoader.swift` — narrow to the video-player path only.
- `Diffusely/Views/LibraryVideoPlayer.swift` — update `State` switch + `load(...)` call.
- `Diffusely/Services/Networking/AppURLSession.swift:3-6` — update the stale comment.

**Delete:**
- `Diffusely/Services/Library/RemoteThumbnailFetcher.swift` + `DiffuselyTests/RemoteThumbnailFetcherTests.swift`
- `Diffusely/Services/Library/LibraryThumbnailStore.swift` + `DiffuselyTests/LibraryThumbnailStoreTests.swift`
- `Diffusely/Services/Library/LibraryImageCache.swift`

**Keep unchanged:** `CivitaiThumbnailURL` (+ tests), `VideoFrameImageDecoder`, `ImageDownsampler`, `NukeImagePipeline`, `CachedAsyncImage`.

---

## Task 1: `LibraryFileMaterializer` (extract iCloud orchestration)

**Files:**
- Create: `Diffusely/Services/Library/LibraryFileMaterializer.swift`
- Test: `DiffuselyTests/LibraryFileMaterializerTests.swift`

This extracts the iCloud download/poll logic currently inside `LibraryMediaLoader.ensureDownloaded` / `checkLocalReadiness` into a standalone nonisolated type, split into two primitives (`isReady`, `download`) so the caller decides when to show a "downloading" UI. `LibraryMediaLoader` itself is rewired to use it in Task 5.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryFileMaterializerTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryFileMaterializerTests {
    @Test func readyForExistingLocalFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await LibraryFileMaterializer.isReady(url: url) == true)
    }

    @Test func notReadyForMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat-missing-\(UUID().uuidString).txt")
        #expect(await LibraryFileMaterializer.isReady(url: url) == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryFileMaterializerTests`
Expected: FAIL — `cannot find 'LibraryFileMaterializer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Services/Library/LibraryFileMaterializer.swift`:

```swift
import Foundation

/// Drives on-demand iCloud materialization of a personal-library file: reports
/// whether the file is already local, and triggers a download + poll when it
/// isn't. Extracted from `LibraryMediaLoader` so both the image-loading path
/// (the Nuke data closure in `LibraryImageRequest`) and the video player path
/// share one implementation. Nonisolated: all work is filesystem / iCloud
/// metadata, safe off the main actor.
enum LibraryFileMaterializer {
    private enum Readiness { case ready, needsDownload }

    /// True if the file is present locally — a non-ubiquitous file that exists,
    /// or a ubiquitous item whose download status is `.current` / `.downloaded`.
    /// Runs the (potentially blocking under a cold cache) iCloud metadata lookup
    /// off the main actor.
    static func isReady(url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            checkLocalReadiness(at: url) == .ready
        }.value
    }

    /// Triggers an iCloud download and polls until the file is current/downloaded
    /// (~2-minute ceiling). Throws `CancellationError` if cancelled mid-poll and
    /// `URLError(.timedOut)` if the ceiling is hit. Call only after `isReady`
    /// returned false.
    static func download(url: URL) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let path = url.path
        for _ in 0..<240 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let downloaded = await Task.detached(priority: .userInitiated) {
                // Fresh URL each iteration: `URL` caches resource values on its
                // backing object, so reusing one would report the status captured
                // on the first read (.notDownloaded) forever and the poll would
                // never observe completion — the thumbnail would spin until the
                // 2-minute timeout even after the file arrived.
                let probe = URL(fileURLWithPath: path)
                let status = (try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
                return status == .current || status == .downloaded
            }.value
            if downloaded { return }
        }
        throw URLError(.timedOut)
    }

    /// Pure snapshot of the on-disk + iCloud-status view of `url`. Touches only
    /// `FileManager.default` and `URL` resource keys, so it's safe on any thread.
    private static func checkLocalReadiness(at url: URL) -> Readiness {
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
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryFileMaterializerTests`
Expected: PASS (2 tests).

> Note: add the two new files to the `Diffusely` / `DiffuselyTests` targets in Xcode if they aren't auto-added (this project uses a `.xcodeproj`; new files must be members of the right target). The `xcodebuild` step fails with "cannot find ... in scope" if a file isn't a target member.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryFileMaterializer.swift DiffuselyTests/LibraryFileMaterializerTests.swift Diffusely.xcodeproj
git commit -m "Add LibraryFileMaterializer (extract iCloud materialization)"
```

---

## Task 2: `LibraryImageRequest` (Nuke request factory + cascade)

**Files:**
- Create: `Diffusely/Services/Library/LibraryImageRequest.swift`
- Test: `DiffuselyTests/LibraryImageRequestTests.swift`

Builds the `ImageRequest(id:data:)` with the stable cache key, and owns the CDN→iCloud byte cascade plus the local-file thumbnail builders (moved here from `LibraryMediaLoader`, where copies still exist until Task 5 — duplicate statics in different types compile fine).

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryImageRequestTests.swift`:

```swift
import Testing
import Foundation
import Nuke
@testable import Diffusely
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct LibraryImageRequestTests {
    // A solid-color JPEG of the given pixel size, as encoded bytes.
    private func makeJPEG(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
        #else
        let image = NSImage(size: size)
        image.lockFocus(); NSColor.red.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
        return image.jpegData(compressionQuality: 0.9)!
        #endif
    }

    @Test func cacheKeyFoldsItemAndDimension() {
        #expect(LibraryImageRequest.cacheKey(itemID: 42, maxDimension: 600) == "library/42@600")
        #expect(LibraryImageRequest.cacheKey(itemID: 42, maxDimension: 1200) == "library/42@1200")
    }

    @Test func gridRequestUsesStableKeyAndKeepsDiskCache() {
        let req = LibraryImageRequest.request(
            itemID: 7, mediaFileName: "7.jpg", isVideo: false,
            maxDimension: LibraryImageRequest.gridDimension)
        #expect(req.imageId == "library/7@600")
        #expect(req.options.contains(.disableDiskCacheWrites) == false)
    }

    @Test func detailRequestDisablesDiskWrites() {
        let req = LibraryImageRequest.request(
            itemID: 7, mediaFileName: "7.jpg", isVideo: false,
            maxDimension: LibraryImageRequest.gridDimension + 600)
        #expect(req.options.contains(.disableDiskCacheWrites) == true)
    }

    @Test func thumbnailImageDownsamplesLocalImageFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lir-\(UUID().uuidString).jpg")
        try makeJPEG(width: 100, height: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(
            await LibraryImageRequest.thumbnailImage(localURL: url, isVideo: false, maxDimension: 32))
        #if canImport(UIKit)
        let maxSide = max(image.size.width * image.scale, image.size.height * image.scale)
        #else
        let maxSide = max(image.size.width, image.size.height)
        #endif
        #expect(maxSide <= 32)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryImageRequestTests`
Expected: FAIL — `cannot find 'LibraryImageRequest' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Services/Library/LibraryImageRequest.swift`:

```swift
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
    /// memory-only. Replaces `LibraryThumbnailStore.gridThumbnailDimension`.
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
        guard let original = originalCDNURL(itemID: itemID, in: dir),
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryImageRequestTests`
Expected: PASS (4 tests). Add the two files to their targets in Xcode if needed (see Task 1 note).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryImageRequest.swift DiffuselyTests/LibraryImageRequestTests.swift Diffusely.xcodeproj
git commit -m "Add LibraryImageRequest (Nuke request factory + tier cascade)"
```

---

## Task 3: Reimplement `LibraryAsyncImage` over `LazyImage`

**Files:**
- Modify: `Diffusely/Views/LibraryAsyncImage.swift` (full rewrite)
- Modify: `Diffusely/Views/LibraryView.swift:190`

No unit test (SwiftUI view); verified by build + the manual pass in Task 7. After this task the grid loads through Nuke, but `LibraryMediaLoader`'s image path still exists (unused by views) — removed in Task 5.

- [ ] **Step 1: Rewrite `LibraryAsyncImage`**

Replace the entire contents of `Diffusely/Views/LibraryAsyncImage.swift` with:

```swift
import SwiftUI
import Nuke
import NukeUI

/// Renders a personal-library image from the local / iCloud container through the
/// shared Nuke pipeline. The CDN→iCloud materialization cascade lives in
/// `LibraryImageRequest`'s data closure; `LazyImage` provides bounded, prioritized
/// loading with automatic off-screen cancellation. Mirrors `CachedAsyncImage`.
struct LibraryAsyncImage: View {
    let itemID: Int
    let mediaFileName: String
    var isVideo: Bool = false
    // Default to the grid thumbnail size so the safe (disk-cached) path is the
    // default — a larger default would silently route callers to the full-original
    // download path. The detail view passes an explicit larger value.
    var maxDimension: CGFloat = LibraryImageRequest.gridDimension
    var contentMode: ContentMode = .fill

    /// Bumping this id rebuilds the LazyImage, re-issuing the request — used for
    /// tap-to-retry after a failure.
    @State private var reloadToken = 0

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else if state.error != nil {
                placeholder.overlay(
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundColor(.orange)
                )
                .contentShape(Rectangle())
                .onTapGesture { reloadToken += 1 }
            } else {
                placeholder
            }
        }
        .id(reloadToken)
    }

    private var request: ImageRequest {
        LibraryImageRequest.request(
            itemID: itemID, mediaFileName: mediaFileName,
            isVideo: isVideo, maxDimension: maxDimension)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.1))
            ProgressView()
        }
    }
}
```

- [ ] **Step 2: Update the `LibraryView` call site**

In `Diffusely/Views/LibraryView.swift`, the `thumbnail(for:)` body passes `maxDimension: LibraryThumbnailStore.gridThumbnailDimension`. Change that line (around line 190) to:

```swift
                    maxDimension: LibraryImageRequest.gridDimension,
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED. (`LibraryThumbnailStore` and `LibraryImageCache` still exist; they're just no longer referenced by these two files.)

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/LibraryAsyncImage.swift Diffusely/Views/LibraryView.swift
git commit -m "Reimplement LibraryAsyncImage over Nuke LazyImage"
```

---

## Task 4: Save-time cache priming + drop thumbnail eviction

**Files:**
- Modify: `Diffusely/Services/Library/LibrarySaveService.swift` (~line 270; imports)
- Modify: `Diffusely/Services/Library/LibraryStore.swift:128,144`
- Modify: `Diffusely/Services/Networking/AppURLSession.swift:3-6`

Removes all remaining references to `LibraryThumbnailStore` and to `LibraryMediaLoader.thumbnailFromLocalOriginal`, so Task 5 (narrowing `LibraryMediaLoader`) and Task 6 (deletions) build cleanly. No unit test — covered by build + Task 7's manual pass.

- [ ] **Step 1: Prime Nuke's cache at save time**

In `Diffusely/Services/Library/LibrarySaveService.swift`, replace the save-time thumbnail block (currently):

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

with:

```swift
        // Prime Nuke's cache now, while the original is local — free, no extra
        // download. The first grid appearance then hits the cache instead of the
        // CDN-first tier. Off the main actor (ImageIO / AVAssetImageGenerator).
        let finalMediaURL = itemsDirectory.appendingPathComponent(metadata.mediaFileName)
        let isVideo = metadata.mediaType == .video
        if let thumb = await LibraryImageRequest.thumbnailImage(
            localURL: finalMediaURL, isVideo: isVideo, maxDimension: LibraryImageRequest.gridDimension) {
            let request = LibraryImageRequest.request(
                itemID: metadata.itemID, mediaFileName: metadata.mediaFileName,
                isVideo: isVideo, maxDimension: LibraryImageRequest.gridDimension)
            ImagePipeline.shared.cache.storeCachedImage(
                ImageContainer(image: thumb), for: request, caches: .all)
        }
```

Add the Nuke import at the top of the file (after `import Foundation`):

```swift
import Nuke
```

- [ ] **Step 2: Drop the thumbnail eviction calls in `LibraryStore`**

In `Diffusely/Services/Library/LibraryStore.swift`, delete line 128:

```swift
        LibraryThumbnailStore.shared.remove(itemID: itemID)
```

and line 144:

```swift
        LibraryThumbnailStore.shared.removeAll()
```

(Civitai item IDs are unique and never reused, so an orphaned Nuke cache entry is never re-requested and is reclaimed by `DataCache`'s LRU. `removeAll` on the shared cache would also drop the feed's entries, so we intentionally don't call it.)

- [ ] **Step 3: Update the stale `AppURLSession` comment**

In `Diffusely/Services/Networking/AppURLSession.swift`, change the doc comment on `URLSession.civitai` from:

```swift
    /// Shared session for the Civitai JSON API (and, until the Library migration,
    /// the Library's CDN thumbnail fallback). Image loading uses Nuke's own
    /// pipeline/session.
```

to:

```swift
    /// Shared session for the Civitai tRPC JSON API. All image loading — feed and
    /// Library, including the Library's CDN thumbnail fallback — uses Nuke's own
    /// pipeline/session (`AppImagePipeline`) instead.
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibrarySaveService.swift Diffusely/Services/Library/LibraryStore.swift Diffusely/Services/Networking/AppURLSession.swift
git commit -m "Prime Nuke cache at save time; drop library thumbnail eviction"
```

---

## Task 5: Narrow `LibraryMediaLoader` to the video-player path

**Files:**
- Modify: `Diffusely/Services/Library/LibraryMediaLoader.swift` (large reduction)
- Modify: `Diffusely/Views/LibraryVideoPlayer.swift`

`LibraryMediaLoader` keeps only the AVPlayer path (out of scope for Nuke) and its `.downloading` iCloud spinner, now delegating materialization to `LibraryFileMaterializer`. The image branch, `LibraryImageCache` usage, `LibraryThumbnailStore` usage, and the moved static helpers are removed. After this task, `LibraryThumbnailStore`, `LibraryImageCache`, and `RemoteThumbnailFetcher` are referenced nowhere.

- [ ] **Step 1: Rewrite `LibraryMediaLoader`**

Replace the entire contents of `Diffusely/Services/Library/LibraryMediaLoader.swift` with:

```swift
import Foundation
import AVFoundation

/// Loads a personal-library **video** for playback: transparently materializes
/// the file from iCloud (AVPlayer can't drive that itself), then hands back an
/// `AVPlayer` over the local file. The image path now goes through Nuke via
/// `LibraryImageRequest`; this loader is video-only.
@MainActor
final class LibraryMediaLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double?)   // nil = indeterminate
        case video(AVPlayer)
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.failed, .failed): return true
            case let (.downloading(a), .downloading(b)): return a == b
            case (.video, .video): return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private var loadTask: Task<Void, Never>?

    func load(itemID: Int, mediaFileName: String) {
        if case .video = state { return }       // already playing this media
        guard loadTask == nil else { return }   // a load is already in flight
        loadTask = Task { await run(itemID: itemID, mediaFileName: mediaFileName) }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        // A view that scrolls off cancels the in-flight load. Return to `.idle`
        // unless the player already loaded, so the next `onAppear` cleanly
        // restarts it.
        if case .video = state { return }
        state = .idle
    }

    private func run(itemID: Int, mediaFileName: String) async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else {
            if Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: "Library items directory unavailable")
            state = .failed
            return
        }
        let url = dir.appendingPathComponent(mediaFileName)

        do {
            if await LibraryFileMaterializer.isReady(url: url) == false {
                state = .downloading(nil)
                try await LibraryFileMaterializer.download(url: url)
            }
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

    /// Logs a local-library load failure with the same `[MediaError]` tag used by
    /// `MediaCacheService`, so the cause behind a failed video tile is visible.
    private func logFailure(itemID: Int, mediaFileName: String, reason: String) {
        print("[MediaError] Failed to load library item \(itemID) (\(mediaFileName))")
        print("[MediaError]   \(reason)")
    }
}
```

- [ ] **Step 2: Update `LibraryVideoPlayer`**

In `Diffusely/Views/LibraryVideoPlayer.swift`:

Change the failure case in the `switch loader.state` (currently `case .image, .failed:`) to:

```swift
            case .failed:
```

And change the `onAppear` load call (currently `loader.load(itemID: itemID, mediaFileName: mediaFileName, isVideo: true, maxDimension: 0, as: .player)`) to:

```swift
            loader.load(itemID: itemID, mediaFileName: mediaFileName)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED. If the compiler flags an unreachable/again-exhaustive `switch` in `LibraryVideoPlayer`, confirm the remaining cases are `.idle, .downloading`, `.video(let player)`, and `.failed`.

- [ ] **Step 4: Run the existing library tests to confirm no regression**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryTests -only-testing:DiffuselyTests/LibrarySortTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryMediaLoader.swift Diffusely/Views/LibraryVideoPlayer.swift
git commit -m "Narrow LibraryMediaLoader to the video-player path"
```

---

## Task 6: Delete the retired types and their tests

**Files:**
- Delete: `Diffusely/Services/Library/RemoteThumbnailFetcher.swift`, `DiffuselyTests/RemoteThumbnailFetcherTests.swift`
- Delete: `Diffusely/Services/Library/LibraryThumbnailStore.swift`, `DiffuselyTests/LibraryThumbnailStoreTests.swift`
- Delete: `Diffusely/Services/Library/LibraryImageCache.swift`

- [ ] **Step 1: Confirm nothing references the retired types**

Run: `grep -rn "RemoteThumbnailFetcher\|LibraryThumbnailStore\|LibraryImageCache" --include="*.swift" Diffusely DiffuselyTests`
Expected: no matches (only the files about to be deleted, if anything). If a match remains in non-deleted code, fix it before deleting.

- [ ] **Step 2: Delete the files**

```bash
git rm Diffusely/Services/Library/RemoteThumbnailFetcher.swift \
       Diffusely/Services/Library/LibraryThumbnailStore.swift \
       Diffusely/Services/Library/LibraryImageCache.swift \
       DiffuselyTests/RemoteThumbnailFetcherTests.swift \
       DiffuselyTests/LibraryThumbnailStoreTests.swift
```

Then remove their references from the Xcode project (delete the file entries from the `Diffusely` / `DiffuselyTests` targets so the project parses). Stage `Diffusely.xcodeproj`.

- [ ] **Step 3: Build + full test run**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: ALL TESTS PASS (including the kept `CivitaiThumbnailURLTests` and the new `LibraryFileMaterializerTests` / `LibraryImageRequestTests`).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Delete RemoteThumbnailFetcher, LibraryThumbnailStore, LibraryImageCache"
```

---

## Task 7: Manual verification (the original repro)

**Files:** none (device/simulator testing).

These confirm the behaviors that motivated the migration. Do them on a real iOS device where possible (the original grey-spinner bug was worst on-device).

- [ ] **Step 1: Hard-scroll a large library grid**

Open the Library tab with many saved items and scroll up and down hard.
Expected: thumbnails load and the loading set drains — no permanent grey spinners, no tiles stuck spinning.

- [ ] **Step 2: Offline relaunch reuse**

After viewing the grid, kill the app, enable Airplane Mode, relaunch, open the Library.
Expected: previously-viewed thumbnails appear from Nuke's `DataCache` with no network and no iCloud activity.

- [ ] **Step 3: iCloud eviction round-trip**

For an item evicted from local storage (or after "Optimize iPhone Storage" reclaims it), open the grid online.
Expected: the tile shows the unified loading spinner, the original materializes from iCloud, and the thumbnail appears. (The distinct `icloud.and.arrow.down` affordance is intentionally gone for grid images per the design; it remains for the video player.)

- [ ] **Step 4: Failure + tap-to-retry**

Force a load failure (e.g. open the grid for an evicted item while offline so both CDN and iCloud fail).
Expected: the failure tile (orange triangle) appears; tapping it re-issues the request.

- [ ] **Step 5: Video poster + playback**

Confirm a saved **video** shows a poster-frame thumbnail in the grid and still plays in the detail view (the `LibraryMediaLoader` AVPlayer path), including the `icloud.and.arrow.down` spinner if the file must be materialized first.

- [ ] **Step 6: Save-time priming**

Save a new image to the library and immediately view the grid.
Expected: its thumbnail appears immediately with no network round-trip (the cache was primed at save time).

---

## Self-Review notes (for the implementer)

- **Spec coverage:** every locked decision in the design spec maps to a task — pure `LazyImage` (Task 3), stable cache key + `disableDiskCacheWrites` (Task 2), Path A downsample-in-closure (Task 2 `loadBytes`/`thumbnailImage`), save-time priming (Task 4), drop eviction (Task 4), `LibraryFileMaterializer` extraction (Task 1), narrowing `LibraryMediaLoader` and keeping the video `.downloading` spinner (Task 5), deletions (Task 6).
- **Type consistency:** `LibraryImageRequest.gridDimension` (replacing `LibraryThumbnailStore.gridThumbnailDimension`), `cacheKey(itemID:maxDimension:)`, `request(itemID:mediaFileName:isVideo:maxDimension:)`, and `thumbnailImage(localURL:isVideo:maxDimension:)` are referenced with these exact signatures in Tasks 2–4. `LibraryFileMaterializer.isReady(url:)` / `download(url:)` are used identically in Tasks 2 and 5.
- **Out of scope (do not touch):** video *playback* migration; the tracked `LocalDownloadTask` bare-UUID → -1002 bug; the shared pipeline's `dataCachePolicy` (Path A leaves the feed path untouched).
