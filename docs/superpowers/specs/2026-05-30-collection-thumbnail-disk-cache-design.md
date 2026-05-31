# Collection Thumbnail Disk Cache — Design

**Date:** 2026-05-30
**Status:** Approved (pending implementation)

## Problem

Collection and feed thumbnails (served from Civitai's Cloudflare CDN via
`MediaCacheService`) are only cached **in memory** for the lifetime of the
process. On the first launch of the day — a cold process with no established
connection and a Cloudflare edge that may have evicted our image variants — the
grid shows nothing but grey spinners until a wave of network fetches completes.

There is no on-disk tier, so every app launch re-fetches every visible
thumbnail over the network. The goal: **previously-viewed thumbnails should
load from local disk with zero network on subsequent launches.**

### Why not rely on Civitai's cache headers

The thumbnail URL (`image.civitai.com/.../anim=false,width=450,optimized=true/<id>.jpeg`)
returns a **301 redirect** (cacheable, `max-age=86400`) to a Backblaze-B2-backed
object. The **final image response has no `Cache-Control` and no `Expires`** —
only `Last-Modified`, which B2 reports as the recent cache-write time. With no
explicit freshness, `URLCache` would apply a `Last-Modified` heuristic (~10% of
a few minutes) and **revalidate on nearly every launch** (a `304` round-trip
per thumbnail). That is lighter than a re-download but still hits the network
and still pays the cold-connection handshake — not the zero-network result we
want.

The thumbnails are **immutable**: a given `id` + transform params always yields
identical bytes. So revalidation is unnecessary, and we can safely force-cache
them for a long TTL.

## Approach

Add a disk-backed `URLCache` to the shared `URLSession.civitai`, plus a small
session delegate that force-caches image responses by injecting a long
`Cache-Control` header before storage. This sits transparently **beneath** the
existing networking stack; `MediaCacheService` and `fetchImageWithTimeout` are
unchanged.

Resulting tier stack:

```
RAM (decoded images, MediaCacheService.entries)
  → disk (raw bytes, URLCache)
    → network (Cloudflare CDN)
```

Chosen over a bespoke disk store (à la `LibraryThumbnailStore`) because
collections are HTTP fetches — exactly what `URLCache` is built for — and it
requires no custom keying or eviction code. The library uses a bespoke store
only because it reads **local files**, where `URLCache` does not apply.

## Components

### 1. `URLCache` configuration — `AppURLSession.swift`

```
URLCache(memoryCapacity: 50 MB,
         diskCapacity: 500 MB,
         directory: <Application Support>/NetworkImageCache)
```

- **Application Support** (not the default Caches directory) so the OS will not
  purge it under storage pressure — durability across launches is the point.
- `URLCache` enforces its own LRU within the 500 MB cap, so we write **no
  eviction code**.
- Assigned to the session via `config.urlCache`.

### 2. `ImageCacheForcingDelegate` — new file

A stateless `URLSessionDataDelegate` implementing
`urlSession(_:dataTask:willCacheResponse:completionHandler:)`:

- **If** the response is an `HTTPURLResponse` with status `200`, a
  `Content-Type` of `image/*`, and a body at or below ~2 MB:
  rebuild the `HTTPURLResponse` with `Cache-Control: public, max-age=2592000`
  (30 days) merged into its header fields, wrap it in a `CachedURLResponse`
  (storage policy `.allowed`) with the original data, and pass that to the
  completion handler.
- **Otherwise** (JSON API responses, video payloads, large bodies, non-200):
  pass the original `proposedResponse` through **unchanged**, so dynamic API
  data is never force-cached and the cache is not bloated with video.
- **On any failure** building the modified response: fall back to passing the
  original through (no worse than today's heuristic caching).

### 3. Session construction — `AppURLSession.swift`

`URLSession.civitai` is created with the delegate:

```
URLSession(configuration: config, delegate: ImageCacheForcingDelegate(), delegateQueue: nil)
```

The 20 s / 300 s timeouts already configured on `config` are retained.

## Data Flow

1. **First fetch** of a thumbnail → network → delegate stamps a 30-day
   `Cache-Control` → response stored on disk (and the cacheable 301 redirect is
   stored too).
2. **Every later fetch** (same session or after relaunch) → CFNetwork serves
   the redirect and image from the disk cache with **no network**, before app
   code runs. Default `.useProtocolCachePolicy` serves the now-"fresh" copy
   without revalidation.

`fetchImageWithTimeout` is unchanged; a disk hit simply returns well within the
15 s deadline.

## Scope

- **In scope:** all `image/*` thumbnails fetched through `URLSession.civitai`
  (collection covers, feed/grid images). The library's `RemoteThumbnailFetcher`
  uses the same session and benefits for free.
- **Out of scope:** JSON API responses, video payloads, full-resolution
  detail/zoom images (different path), and any custom RAM-tier changes.

## Error Handling & Concurrency

- Delegate failures fall back to pass-through; no crash, no regression.
- The delegate is stateless — delegate-queue callbacks are inherently safe.

## Testing

- **Unit:** feed the delegate a synthetic `image/*` 200 → assert the returned
  response carries `Cache-Control: ...max-age=2592000`; feed a JSON 200 → assert
  it is passed through untouched; feed an oversized image body → assert
  pass-through.
- **Config:** assert `URLSession.civitai.configuration.urlCache` is non-nil with
  the expected memory/disk capacities.
- **Manual:** relaunch cold, open a previously-viewed collection → thumbnails
  appear instantly with no image requests on the wire.

## Verification Risk

Confirm that the **session-level `willCacheResponse` reliably fires** for tasks
created via the async `data(for:)` API used in `fetchImageWithTimeout`. Expected
to work (session-delegate callbacks fire regardless of how a task is created),
but must be verified explicitly before relying on it. If it does not fire,
fall back to `URLSession.data(for:delegate:)` with a per-task delegate, or the
completion-handler task API.

## Non-Goals / YAGNI

- No bespoke disk store, custom keying, or hand-written eviction.
- No third-party image library.
- No caching of videos or full-resolution originals.
