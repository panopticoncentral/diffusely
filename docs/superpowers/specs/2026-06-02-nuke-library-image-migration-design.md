# Nuke Library Image Migration (Plan 2) — Design

- **Date:** 2026-06-02
- **Status:** Approved for planning
- **Author:** Paul Vick (with Claude)
- **Refines:** `2026-06-02-nuke-image-pipeline-migration-design.md` (the overall migration spec)

## Context

The overall migration spec specifies routing *both* remote and local Library images
through Nuke, retiring `RemoteThumbnailFetcher`, `LibraryThumbnailStore`, and
`LibraryImageCache`. Plan 1 (feed / collections / user-content image loading) is done and
merged (commit `4a9440b`): the shared `AppImagePipeline`, `CachedAsyncImage` over NukeUI
`LazyImage`, and the registered `VideoFrameImageDecoder` are in place. This spec covers the
deferred **Library path** (Plan 2) and records the design decisions specific to it.

The Library image path is structurally different from the feed because it is a multi-tier
loader: disk thumbnail store → CDN-first fetch → iCloud on-demand materialization
(`startDownloadingUbiquitousItem` + a poll loop) → decode. Nuke cannot drive iCloud
materialization itself, so that orchestration must be preserved on our side while Nuke owns
decode, resize, caching, bounded concurrency, prioritization, and off-screen cancellation.

## Decisions (locked)

1. **Pure `LazyImage`, no image loader.** `LibraryAsyncImage` is reimplemented over NukeUI
   `LazyImage(request:)` directly (like `CachedAsyncImage`). The image branch of
   `LibraryMediaLoader` is retired. The whole CDN→iCloud cascade lives inside a single Nuke
   `ImageRequest(id:data:)` data closure.
   - **Consequence:** the distinct "downloading from iCloud" grid spinner
     (`icloud.and.arrow.down`) is dropped in favour of one unified loading spinner. The
     iCloud spinner is *kept* on the video player path (see below).
2. **Single stable cache key per item+size.** The request id is
   `"library/<itemID>@<Int(maxDimension)>"`. Any successful load — whichever tier produced
   it — caches under that one key, so a relaunch never re-attempts the CDN. Folding the
   dimension in keeps the grid (600 px) and detail (full) entries distinct, as
   `LibraryImageCache` did.
3. **Path A — downsample in the closure.** The local-original branch produces small JPEG
   bytes itself (ImageIO downsample for images, `AVAssetImageGenerator` poster frame for
   video), so Nuke's `DataCache` stores a ~600 px JPEG, matching today's
   `LibraryThumbnailStore` footprint. The shared pipeline's `dataCachePolicy` is **not**
   changed — the merged Plan-1 feed path is left untouched (zero blast radius).
   `ImageDownsampler` and the poster-frame extraction are kept.
4. **Detail/full-size requests are memory-cache-only**
   (`ImageRequest.Options.disableDiskCacheWrites`), so full-resolution images are not newly
   duplicated on disk. This matches today's RAM-only `runFullImage`.
5. **Save-time cache priming** replaces save-time thumbnail pre-generation: build the
   thumbnail from the just-saved local original and store it into Nuke's cache under the
   item's stable key, preserving today's instant, no-network first view.
6. **Drop per-item / all eviction.** `LibraryStore.remove` / `removeAll` no longer purge a
   thumbnail store. Civitai item IDs are unique and never reused, so an orphaned Nuke entry
   is never re-requested and is reclaimed by `DataCache`'s LRU.

## Architecture

### `LibraryAsyncImage` (view) — reimplemented

Over `LazyImage(request:)`, mirroring `CachedAsyncImage`: placeholder + `ProgressView`
while loading, image fill on success, tap-to-retry tile on failure (bump a `reloadToken`
used as `.id`). No `@StateObject LibraryMediaLoader`, no `.downloading` state. `LazyImage`
handles off-screen cancellation; the explicit `onAppear`/`onDisappear` load/cancel goes
away. Keeps `contentMode` and the aspect-ratio behaviour.

### `LibraryImageRequest` (new) — request factory

`request(itemID:mediaFileName:isVideo:maxDimension:) -> ImageRequest` builds an
`ImageRequest(id:data:)`:

- **id:** `"library/<itemID>@<Int(maxDimension)>"` (the stable key).
- **processors:** `[.resize(width: maxDimension)]` — near-no-op for the pre-sized local
  branch; active for the rare CDN-mis-served case.
- **options:** `[.disableDiskCacheWrites]` when `maxDimension > gridDimension` (the
  detail path), so full-res images stay memory-only.
- **data closure** (`@Sendable`, runs only on a true cache miss) — reproduces today's tier
  order, returning small JPEG `Data`:
  1. **CDN-first:** read the sidecar `originalCDNURL`, derive a static-thumbnail URL via
     `CivitaiThumbnailURL` (kept), fetch with a 10 s-timeout `URLRequest` on a plain
     session (not `URLSession.civitai`, reserved for tRPC JSON). Return the bytes on HTTP
     200. If the CDN mis-serves video bytes, the registered `VideoFrameImageDecoder`
     extracts a frame — a free improvement over the old `RemoteThumbnailFetcher`.
  2. **iCloud original fallback:** `LibraryFileMaterializer.materialize(originalURL)`;
     record `.downloaded` access; then build bytes from the now-local file —
     `ImageDownsampler.downsample(…)` → `jpegData` for images, `extractPosterFrame(…)` →
     `jpegData` for video (handing a whole video file to Nuke would buffer it in RAM and
     re-stage a temp file). Throw on failure so `LazyImage` shows the failure tile.

`LibraryImageRequest.gridDimension` (= 600) replaces
`LibraryThumbnailStore.gridThumbnailDimension` as the shared grid-size constant and the
`LibraryAsyncImage` default.

### `LibraryFileMaterializer` (new, nonisolated) — iCloud orchestration

Extracts today's `LibraryMediaLoader.ensureDownloaded` / `checkLocalReadiness` (and the
items-directory lookup) into a reusable `materialize(url:) async throws -> Bool` (returns
whether it had to download). Preserves the fresh-URL-per-iteration poll loop and the
~2-minute ceiling. Used by both the request closure and the surviving video player path.

### `LibraryMediaLoader` — narrowed to video player only

Keeps `load(… as: .player)`, `runVideoPlayer`, and the `.downloading` state (the video
player still shows the iCloud spinner), now delegating materialization to
`LibraryFileMaterializer`. The entire image branch is removed: `runGridThumbnail`,
`runFullImage`, the `LibraryImageCache` fast-path, `persistThumbnail`, `Output.image`, and
the `.image` State case. `thumbnailFromLocalOriginal` / `extractPosterFrame` move to where
the closure and `LibrarySaveService` can share them (a nonisolated helper — co-located with
`LibraryImageRequest` or kept as shared statics).

## Deletions / consolidation

- **Delete:** `RemoteThumbnailFetcher` (+ `RemoteThumbnailFetcherTests`),
  `LibraryThumbnailStore` (+ `LibraryThumbnailStoreTests`), `LibraryImageCache`.
- **Keep:** `CivitaiThumbnailURL` (+ tests) — the closure still derives CDN URLs.
  `VideoFrameImageDecoder` unchanged. `ImageDownsampler` kept (Path A).
- **`LibraryView.thumbnail(for:)`:** replace the `LibraryThumbnailStore.gridThumbnail-
  Dimension` argument with `LibraryImageRequest.gridDimension`.
- **`LibrarySaveService`:** replace `LibraryThumbnailStore.shared.store(…)` pre-generation
  with Nuke cache priming.
- **`LibraryStore.remove` / `removeAll`:** drop the thumbnail-eviction calls.

## Error handling & loading states

- Loading: placeholder + `ProgressView` via `LazyImage`'s state (one unified spinner).
- Failure: tap-to-retry tile, matching `CachedAsyncImage`.
- Video-mis-served CDN posters: handled by the registered `VideoFrameImageDecoder`; on
  extraction failure, falls through to the failure tile.
- Video **player** path: unchanged, keeps its own `.downloading` iCloud spinner.

## Testing

- **Add:** `LibraryImageRequest` local-bytes tests — image fixture → downsampled JPEG
  `Data`; video fixture → poster-frame JPEG `Data`; and that the built `ImageRequest`
  carries the expected stable key and `disableDiskCacheWrites` for the detail size. (The
  CDN-vs-iCloud cascade is iCloud-bound and stays manual.)
- **Keep:** `CivitaiThumbnailURLTests`.
- **Remove:** `RemoteThumbnailFetcherTests`, `LibraryThumbnailStoreTests`.
- **Manual:** scroll a large library grid hard (no permanent spinners, loading set drains);
  relaunch offline and confirm previously-viewed thumbnails load from `DataCache` with no
  network; evict an item via iCloud and confirm on-demand re-download still works (now under
  the unified spinner).

## Out of scope

- Video **playback** stays on `LibraryMediaLoader`'s AVPlayer path (unchanged).
- The tracked `LocalDownloadTask` bug (a task built from a bare UUID string → -1002
  "unsupported URL") is **not** fixed here; be aware of it when touching the download code.
