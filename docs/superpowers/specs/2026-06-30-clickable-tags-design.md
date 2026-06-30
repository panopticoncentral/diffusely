# Clickable Tags on Image/Video Detail

**Date:** 2026-06-30
**Status:** Approved design, ready for implementation plan

## Problem

When viewing an image or video in the detail view, there is no way to see the tags
associated with that media or to discover other content sharing a tag. We want to show
the media's tags on the detail screen and make each tag tappable, opening a feed filtered
to that tag with the usual sort and timeframe controls — mirroring how civitai.com behaves.

## Key findings (verified against current code and Civitai source)

- **The website does not use the feed's `tags` array.** On the image detail page
  (`civitai/src/components/Image/DetailV2/ImageDetail2.tsx`), tags render via a `VotableTags`
  component that calls a dedicated endpoint, **`tag.getVotableTags`** (`{ type: "image", id }`).
  The server (`tag.service.ts`) returns an already-denoised list: when good WD14
  (SD-classifier) tags exist it suppresses the noisy AWS-Rekognition auto-tags, keeping only
  moderation tags plus a small allow-list of style/subject tags, and drops un-voted,
  non-finalized tags. We mirror this rather than inventing our own filtering.
- **The detail page shows 6 tags collapsed**, with a "show more" expander, sorted
  moderation-first then by score.
- **Tags link to `/images?tags=<tagId>`** — a feed filtered by the numeric **tag ID** (not
  name), using the same infinite-images query. The backend joins on `TagsOnImageDetails.tagId`
  and matches images carrying **all** listed tag IDs.
- **`tag.getVotableTags` is a public endpoint.** `entityType: "image"` covers videos too —
  Civitai videos are images with `type: "video"`.
- **The app's feed fetch is reusable.** `CivitaiService.fetchImages(videos:limit:period:sort:collectionId:username:)`
  (CivitaiService.swift:138) and `loadMoreImages(...)` (CivitaiService.swift:233) already
  accept scoping parameters following a clear conditional pattern. `image.getInfinite`
  accepts a `tags: number[]` filter. The service sends a fixed `browsingLevel = 31`
  (all levels) on every query (CivitaiService.swift:74).
- **`UserContentView` is the scoped-feed precedent.** It owns its own `CivitaiService`,
  `selectedPeriod`/`selectedSort`, a sort+timeframe filter menu, and infinite scroll. It is
  presented from `ImageDetailView` via iOS `fullScreenCover` (ImageDetailView.swift:173) and
  macOS `navigationDestination` (ImageDetailView.swift:158). It carries a macOS pushed-local-state
  workaround (UserContentView.swift:22-37) so tapping content inside a pushed scoped feed does
  not collapse the navigation stack.
- **No tag model exists yet** in the app.

## Scope

**In scope**

- A **Tags** section on the image/video detail view showing the curated tag list from
  `tag.getVotableTags`, collapsed to 6 chips with a "Show more" expander.
- Each tag chip is tappable and opens a tag-filtered feed for that tag.
- The tag feed reuses the existing feed plumbing, scoped by tag ID, with the standard
  sort + timeframe controls.

**Out of scope (YAGNI)**

- Tags on feed thumbnails or anywhere other than the detail view.
- Multi-tag (AND) selection — tapping one tag opens a single-tag feed.
- Tag voting or adding (the website's `VotableTags` supports voting; we are read-only).
- A standalone tag search/browse screen.

## Design

### 1. Tag data: model + fetch

New model `CivitaiVotableTag`:

```swift
struct CivitaiVotableTag: Codable, Identifiable, Hashable {
    let id: Int          // drives the feed filter and the SwiftUI list key
    let name: String     // chip label
    let type: String     // "UserGenerated" | "Label" | "Moderation" | "System"
    let nsfwLevel: Int
    let score: Int
}
```

New service method on `CivitaiService`:

```swift
func fetchVotableTags(imageId: Int) async -> [CivitaiVotableTag]
```

- Calls `tag.getVotableTags` with input `{ type: "image", id: imageId }`. `type: "image"`
  covers videos too. Uses the same `browsingLevel` the rest of the app uses.
- Returns the server-curated list. We do **not** re-implement source/category filtering —
  the server already did it.
- Client-side ordering to match the site: moderation tags (`type == "Moderation"`) first,
  then by `score` descending.
- On error, returns an empty array (tags are non-critical).

### 2. Tag-filtered feed (service)

- Add `tags: [Int]? = nil` to both `fetchImages(...)` and `loadMoreImages(...)`.
- When `tags` is non-nil and non-empty, set `inputParams["tags"] = tags`. This is the only
  change to the existing service methods; it follows the same conditional pattern as
  `collectionId`/`username`.
- **Validate during implementation:** whether the `tags` filter requires `useIndex` to be
  turned off (the website's tag feed uses the DB path, not the Meilisearch index). If tag
  filtering returns wrong/empty results with `useIndex = true`, omit `useIndex` when `tags`
  is set. Not a blocker — a thing to confirm with a live request.

### 3. Detail view: Tags section

In `ImageDetailView`, after `GenerationDataView` (ImageDetailView.swift:136):

- A `Divider()` followed by a "Tags" section.
- Tags loaded in `.task` (independently of generation data) via `fetchVotableTags(imageId:)`.
- Rendered as a wrapping flow of chip-style `Button`s, **collapsed to 6** with a "Show more"
  toggle that reveals the rest. The collapse state is local `@State`.
- **Empty or error → the entire section (including the "Tags" header and divider) is
  hidden.** No error UI; no blocking spinner — generation data and tags load independently.
- Tapping a chip opens the tag feed for that tag's `id` + `name`, with media type derived
  from `image.isVideo ? .video : .image`.

### 4. TagFeedView

New view modeled on `UserContentView`:

- Inputs: tag `id: Int`, tag `name: String`, and a fixed media type (`videos: Bool`).
- Owns `@StateObject private var civitaiService = CivitaiService()`, `selectedPeriod`,
  `selectedSort`. No media-type picker (the type is fixed from the tap context).
- Chrome mirrors `UserContentView`: title = the tag name, a close button on iOS, and the
  same sort + timeframe filter menu. **Defaults: `.mostCollected` / `.week`** (matching the
  app's primary feed), adjustable via the menu.
- Grid/list and infinite scroll reuse the existing item views and `maybeLoadMore` pattern,
  calling `fetchImages(videos:period:sort:tags:[id])` and `loadMoreImages(..., tags: [id])`.
- **Presentation mirrors `UserContentView` exactly:** iOS `fullScreenCover(item:)`, macOS
  `navigationDestination(item:)` from `ImageDetailView`, including the macOS pushed-local-state
  workaround (UserContentView.swift:22-37) so tapping an image inside the tag feed does not
  collapse the navigation stack.
- Tapping an image in the tag feed opens `ImageDetailView` again; from there another tag can
  be tapped, opening another `TagFeedView` (stacked covers/pushes). This is acceptable and
  matches the website.

## Testing

- **Decode test:** a representative `tag.getVotableTags` JSON response decodes into
  `[CivitaiVotableTag]` with correct fields.
- **Service test:** `tags` appears in the `image.getInfinite` request body when provided to
  `fetchImages`/`loadMoreImages`, and is absent when `nil`/empty.
- **Ordering test:** `fetchVotableTags` returns moderation tags first, then by descending score.
- **Manual UI verification on both iOS and macOS** (dual-target rule): tags appear on a
  detail view, "Show more" reveals the rest, tapping a chip opens a correctly-titled,
  correctly-typed tag feed whose sort/timeframe menu works, and back/dismiss returns to the
  originating detail view without collapsing the stack.
