# Nuke Feed Image Migration — Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bespoke `@MainActor` image-load pipeline for the Civitai feed / collections / user-content surfaces with a shared Nuke pipeline, fixing the permanent grey-spinner wedge.

**Architecture:** A single configured `ImagePipeline.shared` (Nuke `DataLoader` with its own session, on-disk `DataCache`, in-memory `ImageCache`, a registered custom video-frame decoder). `CachedAsyncImage` becomes a thin wrapper over NukeUI `LazyImage`. `MediaCacheService` shrinks to video-only; `URLSession.civitai` reverts to a plain JSON-API session; the `ImageResponseCacheForcer` caching layer is deleted. The Library path is **out of scope** (Plan 2).

**Tech Stack:** Swift, SwiftUI, Nuke + NukeUI (SPM), AVFoundation (video-frame fallback), Swift Testing.

**Design spec:** `docs/superpowers/specs/2026-06-02-nuke-image-pipeline-migration-design.md`

---

## File Structure

- **Create** `Diffusely/Services/Media/NukeImagePipeline.swift` — pipeline configuration + install entry point.
- **Create** `Diffusely/Services/Media/VideoFrameImageDecoder.swift` — custom Nuke decoder for video-byte responses (static posters).
- **Create** `DiffuselyTests/VideoFrameImageDecoderTests.swift` — tests for the video-vs-image detection.
- **Create** `DiffuselyTests/NukeImagePipelineTests.swift` — asserts the shared pipeline is configured (DataCache + ImageCache).
- **Modify** `Diffusely/DiffuselyApp.swift` — install the pipeline at launch.
- **Modify** `Diffusely/Views/CachedAsyncImage.swift` — reimplement over `LazyImage`.
- **Modify** `Diffusely/Services/Media/MediaCacheService.swift` — delete image path + all `[mediadiag]` debug code; repoint `preloadImages`.
- **Modify** `Diffusely/Services/Networking/AppURLSession.swift` — revert to a plain session.
- **Modify** `Diffusely/Services/Library/RemoteThumbnailFetcher.swift` — drop the `storeIfCacheable` call (kept alive for Plan 2).
- **Modify** `DiffuselyTests/AppURLSessionCacheTests.swift` — drop the cache/delegate assertions.
- **Delete** `Diffusely/Services/Networking/ImageResponseCacheForcer.swift` and `DiffuselyTests/ImageResponseCacheForcerTests.swift`.

Build commands (this is a macOS + iOS app; build both where relevant):
- iOS: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
- Tests: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests`

---

## Task 1: Add the Nuke package (manual, in Xcode)

**This step is done by the human in Xcode — the rest of the plan won't compile until it's complete.**

- [ ] **Step 1: Add the package**

In Xcode: File → Add Package Dependencies → enter `https://github.com/kean/Nuke` → Dependency Rule "Up to Next Major Version" from `12.0.0` → Add Package. When prompted for products, add **`Nuke`** and **`NukeUI`** to the **Diffusely** target (not the test targets).

- [ ] **Step 2: Verify it resolves and builds**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **` (no source changes yet; just confirms the package resolves and links).

- [ ] **Step 3: Commit the package resolution**

```bash
git add Diffusely.xcodeproj
git commit -m "Add Nuke + NukeUI Swift package dependency"
```

---

## Task 2: Shared Nuke pipeline

**Files:**
- Create: `Diffusely/Services/Media/NukeImagePipeline.swift`
- Create: `DiffuselyTests/NukeImagePipelineTests.swift`
- Modify: `Diffusely/DiffuselyApp.swift`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/NukeImagePipelineTests.swift`:

```swift
import Testing
import Nuke
@testable import Diffusely

@Suite struct NukeImagePipelineTests {
    @Test func configureInstallsSharedPipelineWithCaches() {
        AppImagePipeline.configure()
        let config = ImagePipeline.shared.configuration
        #expect(config.dataCache != nil)        // durable cross-launch disk cache
        #expect(config.imageCache != nil)       // in-memory decoded tier
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests/NukeImagePipelineTests`
Expected: FAIL to compile — `Cannot find 'AppImagePipeline' in scope`.

- [ ] **Step 3: Create the pipeline**

Create `Diffusely/Services/Media/NukeImagePipeline.swift`:

```swift
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
```

- [ ] **Step 4: Add the decoder registration stub so it compiles**

(The full decoder is built in Task 3. For now add a minimal `registerOnce()` so this task compiles and its test passes.) Create `Diffusely/Services/Media/VideoFrameImageDecoder.swift`:

```swift
import Foundation
import Nuke

/// Custom Nuke decoder that turns a `video/*` response into an extracted still
/// frame, so a static poster URL that the CDN mis-serves as raw video still
/// renders. Fully implemented in Task 3.
struct VideoFrameImageDecoder {
    private static var registered = false

    /// Registers the decoder with Nuke's shared registry exactly once.
    static func registerOnce() {
        guard !registered else { return }
        registered = true
        // Real registration added in Task 3.
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests/NukeImagePipelineTests`
Expected: PASS.

- [ ] **Step 6: Install the pipeline at app launch**

In `Diffusely/DiffuselyApp.swift`, add `import Nuke` is not needed; call `configure()` in the `App`'s `init()`. Add to the `App` struct:

```swift
    init() {
        AppImagePipeline.configure()
    }
```

(If an `init()` already exists, add the `AppImagePipeline.configure()` line as its first statement.)

- [ ] **Step 7: Build**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Diffusely/Services/Media/NukeImagePipeline.swift Diffusely/Services/Media/VideoFrameImageDecoder.swift DiffuselyTests/NukeImagePipelineTests.swift Diffusely/DiffuselyApp.swift
git commit -m "Add shared Nuke image pipeline + install at launch"
```

---

## Task 3: Video-frame fallback decoder

**Files:**
- Modify: `Diffusely/Services/Media/VideoFrameImageDecoder.swift`
- Create: `DiffuselyTests/VideoFrameImageDecoderTests.swift`

Detection is factored into a pure function so it's unit-testable without constructing a Nuke `ImageDecodingContext`.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/VideoFrameImageDecoderTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct VideoFrameImageDecoderTests {
    // ftyp box at bytes 4..<8 marks an MP4/QuickTime container.
    private func mp4Header() -> Data {
        var d = Data([0x00, 0x00, 0x00, 0x18]) // box size
        d.append(Data("ftypmp42".utf8))        // 'ftyp' + brand
        d.append(Data(repeating: 0, count: 8))
        return d
    }
    private func jpegHeader() -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) }

    @Test func detectsVideoByContentType() {
        #expect(VideoFrameImageDecoder.isVideo(contentType: "video/mp4", data: jpegHeader()))
        #expect(VideoFrameImageDecoder.isVideo(contentType: "VIDEO/MP4", data: jpegHeader()))
    }

    @Test func detectsVideoByMagicBytes() {
        #expect(VideoFrameImageDecoder.isVideo(contentType: nil, data: mp4Header()))
    }

    @Test func treatsImageAsNotVideo() {
        #expect(!VideoFrameImageDecoder.isVideo(contentType: "image/jpeg", data: jpegHeader()))
        #expect(!VideoFrameImageDecoder.isVideo(contentType: nil, data: jpegHeader()))
    }

    @Test func shortDataIsNotVideo() {
        #expect(!VideoFrameImageDecoder.isVideo(contentType: nil, data: Data([0x00, 0x01])))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests/VideoFrameImageDecoderTests`
Expected: FAIL to compile — `isVideo(contentType:data:)` does not exist.

- [ ] **Step 3: Implement the decoder**

Replace the contents of `Diffusely/Services/Media/VideoFrameImageDecoder.swift`:

```swift
import Foundation
import AVFoundation
import Nuke
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Nuke decoder for the case where a still-poster URL is mis-served as raw video
/// bytes (the CDN sometimes ignores `transcode=true,anim=false`). Detects video
/// payloads and extracts frame 0 via AVFoundation so the tile shows a poster
/// instead of failing. Normal image bytes are left to Nuke's default decoders.
struct VideoFrameImageDecoder: ImageDecoding {
    private static var registered = false

    static func registerOnce() {
        guard !registered else { return }
        registered = true
        ImageDecoderRegistry.shared.register { context in
            let contentType = (context.urlResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")
            return isVideo(contentType: contentType, data: context.data) ? VideoFrameImageDecoder() : nil
        }
    }

    /// Pure detection: video if the content-type starts with `video/`, or the
    /// bytes are an ISO-BMFF/QuickTime container (`ftyp` box at offset 4).
    static func isVideo(contentType: String?, data: Data) -> Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        guard data.count >= 12 else { return false }
        let ftyp = Data("ftyp".utf8)
        return data.subdata(in: 4..<8) == ftyp
    }

    enum DecodeError: Error { case noFrame }

    func decode(_ data: Data) throws -> ImageContainer {
        guard let image = Self.extractFrame(from: data) else { throw DecodeError.noFrame }
        return ImageContainer(image: image)
    }

    /// Writes the bytes to a temp file (AVURLAsset needs a URL) and pulls a frame.
    private static func extractFrame(from data: Data) -> PlatformImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try data.write(to: tmp) } catch { return nil }

        let asset = AVURLAsset(url: tmp)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = [CMTime(seconds: 0.5, preferredTimescale: 600), .zero]
        for time in times {
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            #if canImport(UIKit)
            return PlatformImage(cgImage: cg)
            #elseif canImport(AppKit)
            return PlatformImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            #endif
        }
        return nil
    }
}
```

Note: `UUID().uuidString` here is runtime app code (not a workflow script), so it is fine.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests/VideoFrameImageDecoderTests`
Expected: PASS (all four).

- [ ] **Step 5: Build the app target**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Media/VideoFrameImageDecoder.swift DiffuselyTests/VideoFrameImageDecoderTests.swift
git commit -m "Implement video-frame fallback decoder for Nuke"
```

---

## Task 4: Reimplement `CachedAsyncImage` over Nuke `LazyImage`

**Files:**
- Modify: `Diffusely/Views/CachedAsyncImage.swift` (full rewrite)

This is a SwiftUI view; verification is build + the manual repro in Task 8. Preserve the public API (`init(url:expectedAspectRatio:)`), placeholder/spinner, and tap-to-retry.

- [ ] **Step 1: Rewrite the view**

Replace the contents of `Diffusely/Views/CachedAsyncImage.swift`:

```swift
import SwiftUI
import Nuke
import NukeUI

/// Loads a remote image through the shared Nuke pipeline. `LazyImage` provides
/// bounded, prioritized loading with automatic cancellation when the cell scrolls
/// off-screen — replacing the bespoke MediaCacheService image path.
struct CachedAsyncImage: View {
    let url: String
    var expectedAspectRatio: CGFloat?

    /// Bumping this id rebuilds the LazyImage, which re-issues the request — used
    /// for tap-to-retry after a failure.
    @State private var reloadToken = 0

    init(url: String, expectedAspectRatio: CGFloat? = nil) {
        self.url = url
        self.expectedAspectRatio = expectedAspectRatio
    }

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable()
            } else if state.error != nil {
                placeholder.overlay(
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundColor(.orange)
                        Text("Tap to retry").font(.caption)
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { reloadToken += 1 }
            } else {
                placeholder
            }
        }
        .id(reloadToken)
    }

    private var request: ImageRequest? {
        guard let u = URL(string: url) else { return nil }
        return ImageRequest(url: u, processors: [.resize(width: AppImagePipeline.maxDimension)])
    }

    @ViewBuilder
    private var placeholder: some View {
        if let ratio = expectedAspectRatio {
            Rectangle().fill(Color.gray.opacity(0.1))
                .aspectRatio(ratio, contentMode: .fit)
                .overlay(ProgressView())
        } else {
            Rectangle().fill(Color.gray.opacity(0.1))
                .overlay(ProgressView())
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **`. (`MediaCacheService`'s image methods are now unused by views but still compile; they're removed in Task 5.)

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/CachedAsyncImage.swift
git commit -m "Render CachedAsyncImage via Nuke LazyImage"
```

---

## Task 5: Strip the `MediaCacheService` image path + debug code; repoint `preloadImages`

**Files:**
- Modify: `Diffusely/Services/Media/MediaCacheService.swift`

Goal: `MediaCacheService` becomes **video-only**. Remove every image-only member and all `[mediadiag]` instrumentation. Keep the video path (`loadVideoAsync`, `videoLoadCompleted`, `pendingVideoLoads`, `activeVideoLoads`, `maxConcurrentVideoLoads`, `videoLoadTimeout`, `cancelLoad`, `clearCache`, the memory-pressure handler, `getPlayer`) intact.

- [ ] **Step 1: Remove image-only members**

Delete from `MediaCacheService`:
- `DebugDS` (the whole `enum DebugDS { ... }` above the class).
- `inFlightImageFetches`, `debugEverSeen`, `dlog(_:)`, `startStuckCellReporter()` and its call in `init` (leave `init` calling only `setupMemoryPressureHandling()`).
- `imageLoadTimeout`, `maxConcurrentImageLoads`, `activeImageLoads`, `pendingImageLoads`.
- `fetchImageWithTimeout(_:)`, `loadImageAsync(url:)`, `startImageLoad(...)`, `imageLoadCompleted()`.
- The `else` (image) branch in `loadMedia` and the image branches in `retryFailed` / `getMediaState` callers — see Step 2 for the rewritten `loadMedia`.
- On `CacheEntry`, delete `isQueued` and `loadStartedAt`.
- In `clearCache()`, delete the `pendingImageLoads.removeAll()` / `activeImageLoads = 0` lines.
- Any `ImageDownsampler` / `ImageResponseCacheForcer` references in the image path (they vanish with `loadImageAsync`).

- [ ] **Step 2: Make `loadMedia` video-only**

`loadMedia` is now only ever called with `isVideo: true` (from `CachedVideoPlayer`/`LibraryVideoPlayer`) and by `preloadImages` for video items. Replace the method body so the image branch is gone:

```swift
    func loadMedia(url: String, isVideo: Bool, priority: TaskPriority = .medium) {
        // Images are handled by the Nuke pipeline (see CachedAsyncImage). This
        // service is video-only; ignore any non-video request defensively.
        guard isVideo else { return }

        let entry = getOrCreateEntry(for: url)
        guard entry.content == nil else { return }
        guard entry.loadingTask == nil else { return }

        entry.state = .loading

        if pendingVideoLoads.contains(where: { $0.url == url }) { return }
        if activeVideoLoads >= maxConcurrentVideoLoads {
            pendingVideoLoads.append((url: url, priority: priority))
            return
        }
        activeVideoLoads += 1
        let task = Task(priority: priority) {
            await loadVideoAsync(url: url)
            videoLoadCompleted()
        }
        entry.loadingTask = task
    }
```

- [ ] **Step 3: Repoint `preloadImages`**

`preloadImages` is called from `PostDetailView` and `CivitaiService` with mixed image/video items. Route images through Nuke's prefetcher and videos through the video path. Replace `preloadImages`:

```swift
    private let imagePrefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .diskCache   // warm the durable cache without holding decoded images in memory
    )

    func preloadImages(_ images: [CivitaiImage]) {
        var imageRequests: [ImageRequest] = []
        for image in images {
            let url = image.detailURL
            if image.isVideo {
                let currentState = getMediaState(for: url)
                if currentState == .idle {
                    loadMedia(url: url, isVideo: true, priority: .utility)
                } else if case .failed = currentState {
                    loadMedia(url: url, isVideo: true, priority: .utility)
                }
            } else if let u = URL(string: url) {
                imageRequests.append(ImageRequest(url: u, processors: [.resize(width: AppImagePipeline.maxDimension)]))
            }
        }
        if !imageRequests.isEmpty {
            imagePrefetcher.startPrefetching(with: imageRequests)
        }
    }
```

Add `import Nuke` at the top of `MediaCacheService.swift`.

- [ ] **Step 4: Build**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **`. If the compiler flags a leftover reference to a deleted member (`getImage`, `retryFailed(isVideo:false)`, etc.), it is dead image-path code — remove it. `getImage(for:)` is no longer used by any view (CachedAsyncImage no longer calls it); delete it if the build flags it as the only remaining issue, otherwise leave it.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests`
Expected: PASS (no test referenced the deleted image methods).

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Media/MediaCacheService.swift
git commit -m "Make MediaCacheService video-only; prefetch feed images via Nuke"
```

---

## Task 6: Delete `ImageResponseCacheForcer` and its last caller

**Files:**
- Modify: `Diffusely/Services/Library/RemoteThumbnailFetcher.swift`
- Delete: `Diffusely/Services/Networking/ImageResponseCacheForcer.swift`
- Delete: `DiffuselyTests/ImageResponseCacheForcerTests.swift`

`RemoteThumbnailFetcher` (still used by the Library path until Plan 2) is the only remaining caller of `storeIfCacheable` after Task 5.

- [ ] **Step 1: Remove the `storeIfCacheable` call**

In `Diffusely/Services/Library/RemoteThumbnailFetcher.swift`, restore the default `fetch` closure to a plain fetch:

```swift
    init(fetch: @escaping Fetch = { url in
        let request = URLRequest(url: url, timeoutInterval: RemoteThumbnailFetcher.timeout)
        return try await URLSession.civitai.data(for: request)
    }) {
        self.fetch = fetch
    }
```

- [ ] **Step 2: Delete the files**

```bash
git rm Diffusely/Services/Networking/ImageResponseCacheForcer.swift DiffuselyTests/ImageResponseCacheForcerTests.swift
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **` (no remaining references to `ImageResponseCacheForcer`).

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Services/Library/RemoteThumbnailFetcher.swift
git commit -m "Delete ImageResponseCacheForcer; Nuke owns image caching"
```

---

## Task 7: Revert `URLSession.civitai` to a plain JSON-API session

**Files:**
- Modify: `Diffusely/Services/Networking/AppURLSession.swift`
- Modify: `DiffuselyTests/AppURLSessionCacheTests.swift`

The session is now only used by `CivitaiService` (tRPC) and `RemoteThumbnailFetcher`. It no longer needs a `URLCache` (Nuke owns image caching). This task removes now-obsolete cache assertions and simplifies the session together — it is not a red→green cycle, so do the two edits (Steps 1 and 2) before running tests in Step 3.

- [ ] **Step 1: Replace the obsolete test assertions**

The committed `AppURLSessionCacheTests` asserts a disk-backed `URLCache`, `.useProtocolCachePolicy`, and `imageCacheDirectory()` — all of which this task removes. Replace the whole file `DiffuselyTests/AppURLSessionCacheTests.swift` with assertions for the plain session:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct AppURLSessionTests {
    @Test func civitaiSessionHasBoundedTimeouts() {
        #expect(URLSession.civitai.configuration.timeoutIntervalForRequest == 20)
        #expect(URLSession.civitai.configuration.timeoutIntervalForResource == 300)
    }

    @Test func civitaiSessionHasNoDelegate() {
        #expect(URLSession.civitai.delegate == nil)
    }
}
```

- [ ] **Step 2: Simplify the session**

Replace the body of `Diffusely/Services/Networking/AppURLSession.swift`:

```swift
import Foundation

extension URLSession {
    /// Shared session for the Civitai JSON API (and, until Plan 2, the Library's
    /// CDN thumbnail fallback). Image loading uses Nuke's own pipeline/session.
    ///
    /// `URLSession.shared` defaults to a 7-day `timeoutIntervalForResource`, so a
    /// stalled connection can hang far longer than any retry/loading logic expects:
    ///   - `timeoutIntervalForRequest` (20s) is a "no progress" guard.
    ///   - `timeoutIntervalForResource` (300s) caps total request time.
    static let civitai: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
}
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests/AppURLSessionTests`
Expected: PASS.

- [ ] **Step 4: Build**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Networking/AppURLSession.swift DiffuselyTests/AppURLSessionCacheTests.swift
git commit -m "Revert URLSession.civitai to a plain JSON-API session"
```

---

## Task 8: Full verification

- [ ] **Step 1: Full test suite (both targets build)**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:DiffuselyTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: iOS build**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual repro on a real device**

Run on the iPhone from Xcode. Open the collection that previously wedged and scroll hard, then let it sit ~10s. Confirm:
- Thumbnails fill in and **keep** filling — no permanent grey spinners, no cells stuck after scrolling stops.
- Scrolling stays responsive while the collection sync runs.
- Static video posters (e.g. collection covers) still render (exercises `VideoFrameImageDecoder`).

- [ ] **Step 4: Manual cross-launch cache check**

View some thumbnails, force-quit, then relaunch in Airplane Mode. Confirm previously-viewed thumbnails appear with no network (served from Nuke's `DataCache`).

- [ ] **Step 5: Confirm no `[mediadiag]` output remains**

While running, confirm the Xcode console shows **no** `[mediadiag]` lines (all debug instrumentation removed).

---

## Self-review notes (covered)

- **Spec coverage:** shared pipeline (Task 2), DataCache/ImageCache (Task 2), resize (per-request in Tasks 4/5), custom video-frame decoder (Task 3), CachedAsyncImage over LazyImage (Task 4), MediaCacheService video-only + debug removal (Task 5), delete ImageResponseCacheForcer + URLCache revert (Tasks 6–7). Library consolidation is explicitly Plan 2 (out of scope here, per the approved split).
- **Out of scope (unchanged here):** `RemoteThumbnailFetcher`, `LibraryThumbnailStore`, `LibraryMediaLoader`, `CivitaiThumbnailURL`, `ImageDownsampler` all remain for Plan 2 (the Library still uses them). `ImageDownsampler` is still used by `LibraryMediaLoader`, so it is **not** deleted in Plan 1.
- **Follow-up (separate):** `CivitaiService.fetchImages` wall-clock timeout.
```
