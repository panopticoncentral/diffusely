# Persistent Library Thumbnail Cache — Design

**Date:** 2026-05-29
**Status:** Approved for planning

## Problem

The personal library grid renders a thumbnail by reading the **full-resolution original** (`<id>.jpeg` / `<id>.mp4`) from the iCloud container and downsampling it at load time. There is no separately stored thumbnail. Because the originals are exactly what iCloud evicts (and what the app's own 2 GB cache limit evicts), browsing the grid is coupled to full originals being materialized locally. Consequences:

- iCloud eviction (or the app's launch-time `enforceCacheLimit`) blanks the grid; cells re-download multi-MB originals just to paint a 600 px thumbnail.
- Scrolling through a large (e.g. 10 GB) library downloads the **entire** library locally, since the cache limit is only enforced at launch — not during a session.
- A device that didn't save an item has no way to show its thumbnail without downloading the original.

**Goal:** grid browsing should never require downloading a full original. Full originals are downloaded only for detail viewing (one item at a time).

## Decisions (from brainstorming)

- **Per-device thumbnail cache**, not synced through iCloud. A one-time rebuild per device is acceptable, so we avoid the complexity of syncing thumbnails and avoid iCloud evicting them.
- **CDN-first generation with iCloud-original fallback.** A device that lacks a thumbnail builds it from Civitai's CDN (small, cheap — like the feed already does), falling back to downloading the iCloud original once if the CDN is unavailable/offline or its URL has rotted.
- **Structure:** a dedicated on-disk `LibraryThumbnailStore`, with the CDN fetch/downsample/video-frame logic factored out of `MediaCacheService` into a shared helper (reused, not duplicated).

## Architecture

Three tiers in front of the originals:

```
RAM: LibraryImageCache  →  Disk: LibraryThumbnailStore  →  Generate (CDN-first → iCloud-original fallback)
```

### Components

**`LibraryThumbnailStore`** (new) — owns the on-disk grid-thumbnail cache. One responsibility: persist/retrieve thumbnails by item id.
- API: `thumbnail(itemID:) -> PlatformImage?`, `store(_ image:, itemID:)`, `remove(itemID:)`, `removeAll()`.
- Backing: `<id>.jpg` files under **Application Support** (e.g. `…/LibraryThumbnails/`). Not Caches (OS may purge under storage pressure, defeating the purpose); not iCloud (per-device). Durable; ~100 MB for the full library.
- One thumbnail per item at the **grid size (600 px)**, JPEG ~0.8 quality.
- All file I/O is safe to call off the main actor.

**CDN thumbnail fetcher.** *(Implementation note: this diverged from the original plan to refactor `MediaCacheService`.)* The library's CDN thumbnail URL requests a **static JPEG frame** (`CivitaiThumbnailURL` forces `anim=false` / `transcode=…,skip=4` and a `.jpeg` extension), so the fetcher never receives raw video bytes and does **not** need `MediaCacheService`'s "CDN served a video instead of a frame" fallback. It is therefore a small, focused `RemoteThumbnailFetcher` (fetch URL → `ImageDownsampler.downsample`) with an injectable fetch closure, and `MediaCacheService` is left untouched — lower risk to the feed, no duplicated logic.

**Unchanged:**
- `LibraryImageCache` (in-memory) stays as the RAM tier in front of the disk store.
- The SwiftData index row (`PersistedLibraryItem`) is **not** changed. The loader reads `originalCDNURL` from the local sidecar `<id>.json` when it needs to generate a thumbnail (sidecars are local and never evicted), so no schema change and no new params threaded through the views.

## Data flow

### Grid thumbnail load (`LibraryMediaLoader`, `.image` output)

1. **RAM hit** (`LibraryImageCache`) → done. (Already exists; synchronous fast-path in `load()`.)
2. **Disk hit** (`LibraryThumbnailStore`) → decode off-main, populate RAM cache, show. **No original download** — evicted items render from the cached thumbnail and stay evicted. This is the core win.
3. **Miss → generate:** read `<id>.json` for `originalCDNURL` → derive a width-limited CDN URL from it (Civitai's CDN supports width-parameterized URLs per `CivitaiImageUrls.md`; reuse the existing CDN URL-construction helpers rather than the raw original URL) → **CDN-first** via the shared helper (fetch that URL, downsample / extract video frame) → on CDN failure/offline, **fall back** to the existing `ensureDownloaded` (iCloud original) path + decode/extract. Store the result to disk + RAM, show.

### Save-time generation (`LibrarySaveService.performSave`)

After the original is downloaded to a temp file and committed (bytes already in hand), generate the thumbnail from those bytes and write it to the store. Free — no extra download. Covers everything saved on this device, so the saving device never needs a rebuild.

### Detail view — unchanged

The full-res image branch (`maxDimension: 2048`) and `LibraryVideoPlayer` still download the iCloud original on demand. Detail is one-at-a-time and wants full quality / playback, so it deliberately bypasses the 600 px thumbnail store. Keeps the fix scoped to browsing.

### Deletion / reset

- `LibraryStore.remove(itemID:)` also calls `thumbnailStore.remove(itemID:)`.
- `resetLibrary()` calls `thumbnailStore.removeAll()`.
- Reconcile-driven prunes do **not** chase orphan thumbnails — a stale ~80 KB file for a vanished item is harmless and overwritten if the id returns.

### Build strategy

**Lazy**, not a background sweep. Thumbnails build as cells appear (step 3) and are cached forever. On a fresh device, the first scroll-past of each item does one cheap CDN fetch, then it's instant. No proactive "download all thumbnails" pass in v1 (possible later enhancement: a one-tap "make available offline" prefetch).

## Error handling

- CDN fetch fails/times out → fall back to iCloud original download.
- Original download fails/times out → `.failed` (orange triangle), same as today.
- **Offline + evicted + no thumbnail yet** (never viewed on this device): both sources unavailable → placeholder/`.failed`. Unavoidable (no local pixels); no worse than today's offline-evicted behavior. Once viewed online once, the thumbnail is cached forever.
- Store **write** failures are best-effort/non-fatal: regenerate next time. A **corrupt/unreadable** thumbnail file reads as `nil` (miss) → regenerate.
- Cancellation (scroll-off) handling is preserved — existing `Task.isCancelled` checks and `cancel()` semantics carry over.

## Concurrency

- Thumbnails are per-`itemID` files, so parallel cell generation needs no global lock (distinct files; a rare double-generate harmlessly writes the same bytes twice).
- `LibraryImageCache` already dedups within a loader.
- All store I/O runs off the main actor.

## Video specifics

- CDN-first naturally yields a frame (the transcode URL returns a JPEG).
- The shared helper retains `MediaCacheService`'s "CDN served a video instead of a frame" fallback.
- The iCloud-original fallback extracts a frame with `AVAssetImageGenerator` (the path added in the #7 fix).

## Testing

- `LibraryThumbnailStore` — unit tests against a temp dir: store→retrieve roundtrip, `remove`, `removeAll`, corrupt-file → `nil`, missing → `nil`. Fully isolatable.
- Shared CDN helper — testable with a stubbed `URLSession` (mirrors `LibraryDateBackfillService`'s injectable seams).
- The loader's tiered ordering is integration-level; the store and helper stay independently testable.

## Out of scope

- Syncing thumbnails across devices.
- A proactive "download all thumbnails" / offline-prefetch pass.
- Changing detail-view (full-original) behavior.
- Real-time / disk-pressure eviction of originals (separate concern; the cache limit remains launch-enforced).
