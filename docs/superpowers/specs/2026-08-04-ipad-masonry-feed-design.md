# iPad Masonry Feed — Design

**Date:** 2026-08-04

## Problem

On macOS the Images, Videos, tag, and user-profile feeds use `MasonryGrid`: equal-width
columns where each cell keeps its media's natural aspect ratio, producing a staggered
Photos-style wall. On iPad the same feeds fall back to a fixed 3-column `LazyVGrid` of
squares, which crops every non-square image to a center square.

The split is purely a leftover: `MasonryGrid` has no platform conditionals and already
ships on iPad through `AuthorContentGrid` (collections and author profiles). Only the
three feed views still branch on `#if os(macOS)`.

## Goal

Regular-width iOS (iPad) renders the same staggered masonry as macOS in all three feeds.
Compact iOS (iPhone) is unchanged.

## Scope

Three views, each with the identical `#if os(macOS)` / `else if isGridLayout` split:

- `Diffusely/Views/ImageFeedView.swift` — Images and Videos tabs
- `Diffusely/Views/TagFeedView.swift` — tag feed
- `Diffusely/Views/UserContentView.swift` — user profile feed

`MasonryGrid` itself needs no changes.

Out of scope: iPhone (compact) keeps its full-width `LazyVStack` list with the username
header and stats row — a different reading experience, not a smaller grid. macOS is
untouched.

## Design

In each view, extract the cell into a helper that keeps platform-specific parameters
guarded, then collapse the two grid branches into one shared `masonryFeed`:

```swift
private func feedCell(_ image: CivitaiImage) -> some View {
    #if os(macOS)
    ImageFeedItemView(image: image, isGridMode: true, preserveAspectRatio: true,
                      showsContextMenu: true, keyboardFocused: image.id == focusedFeedImageID)
    #else
    ImageFeedItemView(image: image, isGridMode: true, preserveAspectRatio: true)
    #endif
}

private var masonryFeed: some View {
    MasonryGrid(items: civitaiService.images,
                aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }) { image in
        feedCell(image).onAppear { maybeLoadMore(for: image) }
    }
}

@ViewBuilder
private var feedContent: some View {
    #if os(macOS)
    masonryFeed
    #else
    if isGridLayout { masonryFeed } else { listFeed }
    #endif
}
```

`TagFeedView` and `UserContentView` follow the same shape with their own cell parameters
(`showsUsername: false` in `UserContentView`) and their own load-more closure.

The `columns` computed property (the three-`GridItem` array) becomes dead in all three
views and is deleted.

### Visual consequences

`preserveAspectRatio: true` carries three changes beyond box shape, all of them matching
macOS: natural aspect ratios, 8pt rounded corners, and `MasonryGrid`'s 8pt gutters plus
8pt outer padding replacing the current 2pt near-edge-to-edge spacing.

Column count derives from `MasonryGrid`'s default `targetColumnWidth` of 240, unchanged
from macOS: 11" iPad portrait → 3 columns (same as today), landscape → 4, 13" Pro
landscape → 5.

### Unchanged behavior

Pagination trigger (`maybeLoadMore` fires on the fifth-from-last and last item — already
how macOS behaves under masonry), the zoom transition into the detail view, the
ellipsis / save-to-Library overlays, and the iPhone list.

## Known limit

`MasonryGrid` is an `HStack` of `LazyVStack`s. Cells within a column materialize lazily,
but the packing pass runs over every loaded item each time a page appends, so it cannot
virtualize across columns. macOS already lives with this and the feed is bounded by how
far the user has scrolled — unlike the Library, where this pattern caused hangs over
thousands of items. If a deep iPad scroll becomes sluggish, the fix is capping loaded
items; that is not in scope here.

## Verification

- Build both the iOS and macOS targets.
- Run the iPad simulator, check the Images feed, a tag feed, and a user profile in
  portrait and landscape against macOS.
- Confirm the iPhone feed is unchanged.
