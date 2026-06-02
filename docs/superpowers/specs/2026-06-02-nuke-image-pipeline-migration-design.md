# Nuke Image Pipeline Migration — Design

- **Date:** 2026-06-02
- **Status:** Approved for planning
- **Author:** Paul Vick (with Claude)

## Context

Users hit permanent grey spinners when scrolling image/video grids (feed, collections,
user content), worst on iOS devices. A long debugging effort traced this through several
layers:

1. A session-wide `URLSessionDataDelegate` with `delegateQueue: nil` serialized every
   request completion through one queue (fixed in commit `6ddf6cf`).
2. Unbounded per-cell image-load concurrency spawned dozens of simultaneous
   `Task` → `withThrowingTaskGroup` → `Task.detached` chains.
3. On the phone (cooperative pool ~5 wide), those chains **starved the thread pool**:
   downsample tasks were submitted but never scheduled, leaving cells stuck in
   `.loading` forever (`task=alive`, `inFlight=0`, ages climbing past 15s).
4. Adding a concurrency cap relocated the stall: load chains are `@MainActor`-isolated and
   contend with the collection **sync** (decodes 519 posts, updates `@Published` state) on
   the main thread, so resumes after the off-main downsample were delayed by seconds
   (`DS return 3434ms`), and stalled chains held all cap slots so the queue never drained.

The root pattern is **uncoordinated concurrency contending for the main actor, the
cooperative thread pool, and a single shared `URLSession`, with no holistic backpressure
or prioritization.** Each point fix moved the bottleneck. Rather than continue patching a
bespoke pipeline, we adopt **Nuke** (`github.com/kean/Nuke`), a battle-tested image
pipeline that already provides bounded concurrency, request prioritization, off-main
decoding, off-screen cancellation, and a two-tier (memory + disk) cache.

## Goals

- Eliminate the permanent grey-spinner class of bug by replacing the bespoke image-load
  pipeline with Nuke.
- Consolidate **all** remote and local image loading onto one pipeline and one cache.
- Preserve current UX: placeholder/spinner, tap-to-retry on failure, downsampled
  thumbnails, cross-launch zero-network reuse, and static posters for video items.
- Keep call-site churn minimal by retaining the existing view names as wrappers.

## Non-goals

- Video **playback** stays on the existing AVPlayer path (`MediaCacheService` video
  branch, `CachedVideoPlayer`/`LibraryVideoPlayer`). Not migrated.
- The feed JSON fetch (`CivitaiService.fetchImages`) wall-clock timeout is a separate
  follow-up (see Out of Scope).

## Decisions (locked)

1. **Scope:** migrate *all* image surfaces — Civitai feed/collections/user content and the
   local Library thumbnails (both CDN-fallback and locally-saved originals).
2. **Caching:** use Nuke's `ImageCache` (memory) + `DataCache` (disk). Delete the bespoke
   network caching (`ImageResponseCacheForcer`, the `URLCache` on `URLSession.civitai`,
   `storeIfCacheable`), `RemoteThumbnailFetcher`, and `LibraryThumbnailStore`.
3. **Library path:** route both remote CDN URLs and local file URLs through Nuke.
4. **Dependency:** user adds Nuke (`Nuke` + `NukeUI` products) to the Diffusely target via
   Xcode SPM; integration code is written against it.
5. **(a) Session split:** Nuke's `DataLoader` owns its own image `URLSession`.
   `URLSession.civitai` reverts to a plain session used only by `CivitaiService` for the
   tRPC JSON API.
6. **(b1) Video-frame fallback:** ported to a custom Nuke `ImageDecoding` that turns a
   `video/*` response into an extracted still frame.
7. **Integration style:** keep `CachedAsyncImage` / `LibraryAsyncImage` as the public
   views; reimplement their internals over NukeUI `LazyImage`. Call sites unchanged.

## Architecture

### Shared pipeline — `NukeImagePipeline.swift` (new)

A single `ImagePipeline`, installed as `ImagePipeline.shared` at app launch, configured with:

- **`DataLoader` with its own session config:** bounded timeouts matching today's tuning
  (`timeoutIntervalForRequest = 20`, `timeoutIntervalForResource = 300`). The session's
  `urlCache` is set to `nil` so Nuke's `DataCache` is the single on-disk cache (no
  double-caching).
- **`DataCache` (disk):** stores original encoded bytes keyed by URL, in Application
  Support (durable across launches, not purged under storage pressure). Because it keys on
  URL and ignores HTTP cache headers, it natively solves the "Backblaze origin sends no
  `Cache-Control`" problem that `ImageResponseCacheForcer` was hacking around.
- **`ImageCache` (memory):** same-session decoded-image tier; gives synchronous cache hits
  so recycled cells paint without a spinner flash.
- **Default processor `ImageProcessors.Resize`** to the platform max dimension
  (600 px on iOS, 1200 px on macOS — matching today's `maxImageDimension`).
- **Custom `ImageDecoding` (video-frame fallback):** detects a video response (by
  `Content-Type: video/*` from the decoding context, falling back to sniffing the MP4
  `ftyp` magic bytes) and extracts frame 0 via `AVAssetImageGenerator`, returning it as the
  decoded image. Ports the logic currently in `MediaCacheService.extractFrameFromVideoResponse`.
  Registered so it only engages for video payloads; normal image bytes use Nuke's default
  decoders.

Nuke's `LazyImage` provides the behaviors that structurally fix the original bug: bounded
concurrency, request prioritization, and automatic cancellation when a view scrolls
off-screen — no task explosion and no `@MainActor`-bound load chains.

### View layer

- **`CachedAsyncImage`** — reimplemented over `LazyImage(url:)`, preserving:
  placeholder + `ProgressView` while loading, `Image` fill on success, and the
  tap-to-retry failed state. Aspect-ratio/`expectedAspectRatio` behavior preserved.
- **`LibraryAsyncImage`** — uses `LazyImage` for both remote CDN URLs and local file URLs
  (Nuke loads, resizes, and caches local files too), replacing `RemoteThumbnailFetcher`
  and the `LibraryThumbnailStore` lookup/generation. Its current load-state UI is
  preserved.

### Videos — unchanged

`CachedVideoPlayer` / `LibraryVideoPlayer` keep using `MediaCacheService`'s AVPlayer path
(3-concurrent cap, 30s timeout). After the migration, `MediaCacheService` is **video-only**:
the image branch (`loadImageAsync`, `fetchImageWithTimeout`, the image concurrency cap,
`ImageDownsampler` usage) and all `[mediadiag]` debug instrumentation are removed.

## Deletions / consolidation

- `ImageResponseCacheForcer` (+ `ImageResponseCacheForcerTests`).
- `URLSession.civitai`'s `urlCache`, `.useProtocolCachePolicy`, and the `imageCacheDirectory`/
  `makeImageURLCache` helpers; `AppURLSessionCacheTests` updated/removed accordingly. The
  `storeIfCacheable` call sites in `MediaCacheService` and `RemoteThumbnailFetcher` removed.
- `RemoteThumbnailFetcher` (+ tests), `LibraryThumbnailStore` (+ tests).
  `CivitaiThumbnailURL` removed if unused after migration.
- `MediaCacheService` image path + all debug instrumentation (`DebugDS`, the stuck-cell
  reporter, `inFlightImageFetches`, the debug-only `loadStartedAt`, the `[mediadiag]`
  logging). The concurrency-cap fields are removed (Nuke owns concurrency for images);
  the `isQueued` field is removed.
- `ImageDownsampler` removed if unused after migration (Nuke's Resize replaces it), or kept
  only if the video-frame decoder reuses it.

## Error handling & loading states

- Loading: existing placeholder + `ProgressView` via `LazyImage`'s state.
- Failure: tap-to-retry tile (re-trigger the load), matching current behavior.
- Video-mis-served posters: handled by the custom decoder; if frame extraction fails, falls
  through to the normal failure tile.

## Testing

- Unit-test the custom video-frame decoder: video bytes → extracted frame; image bytes →
  not handled (passthrough to default decoders); malformed → nil.
- Unit-test `LibraryAsyncImage` local-vs-remote URL routing (local file URL vs CDN URL).
- Remove tests for deleted types (`ImageResponseCacheForcerTests`, `RemoteThumbnailFetcherTests`,
  `LibraryThumbnailStoreTests`, the `URLCache`-specific `AppURLSessionCacheTests` cases).
- Manual verification (the original repro): on an iOS device, scroll a large collection
  hard — confirm no permanent spinners and the loading set drains. Relaunch offline and
  confirm previously-viewed thumbnails load from Nuke's `DataCache` with no network.

## Out of scope (follow-ups)

- `CivitaiService.fetchImages` has no wall-clock timeout; a wedged request can blank the
  feed (observed once during this investigation). Give it the same bounded-timeout
  treatment in a separate change.
- `MediaCacheService` video playback could later move to NukeVideo; not now.

## Rollout notes

- User adds the Nuke package (`Nuke` + `NukeUI`) to the Diffusely target in Xcode before
  integration code is built.
- This migration effectively supersedes the caching approach committed in `6ddf6cf`
  (`ImageResponseCacheForcer` etc.), which is removed here.
