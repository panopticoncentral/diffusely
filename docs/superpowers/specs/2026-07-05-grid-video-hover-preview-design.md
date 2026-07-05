# Grid Video: Poster Frames + On-Demand Playback

**Date:** 2026-07-05
**Status:** Approved design, ready for implementation plan

## Problem

In grid mode, every visible video cell renders an autoplaying `CachedVideoPlayer`.
On macOS especially — where the window is large and dozens of cells are on screen —
this produces a "wall" of videos all playing at once. A `sample` of the running Mac
app while browsing a video grid showed ~40 `com.apple.coremedia.videomediaconverter`
threads and a 1.8 GB peak footprint. It is wasteful and was one malformed frame away
from the layout crash fixed in commit `105ad50`.

We want the macOS Photos model: cells show a still frame; a video plays only when the
user asks for it, and never more than one at a time.

## Key findings (verified against current code)

- **Every grid video autoplays and self-loads.** `ImageFeedItemView.gridContent`
  renders `CachedVideoPlayer(url: image.detailURL, autoPlay: true, isMuted: true)` for
  each video cell (ImageFeedItemView.swift:201-209). `CachedVideoPlayer`'s `.onAppear`
  calls `mediaCache.loadMedia(url:isVideo:)` (CachedVideoPlayer.swift:34-37), so the
  `.mp4` download + decode starts as soon as the cell appears — the source of the
  simultaneous decode pipelines. Gating the *player* on demand therefore gates the
  *load* too; the poster path never touches the video.
- **A poster frame already exists for videos.** `CivitaiImage.thumbnailURL`
  (CivitaiImage.swift:61-71) returns a static JPEG even for videos via the CDN's
  `anim=false` frame extraction (using the API thumbnail when present, else a
  `transcode=true,anim=false,skip=4` frame). `CachedAsyncImage` already loads static
  images this way.
- **`CachedVideoPlayer` is close to on-demand-ready.** It loads through
  `MediaCacheService` (players are cached), takes `autoPlay`/`isMuted`, loops via
  `AVPlayerItemDidPlayToEndTime`, and pauses on `.onDisappear` (CachedVideoPlayer.swift:47-108).
  Its one gap for use as a hover overlay: while `.idle`/`.loading` it draws an opaque
  **black Rectangle + spinner** (lines 28-45), which would flash over the poster.
- **Both platforms funnel through `gridContent`.** macOS `feedContent` uses `MasonryGrid`
  (ImageFeedView.swift:140-147); iOS grid uses `LazyVGrid` (ImageFeedView.swift:152-160).
  Both render `ImageFeedItemView(isGridMode: true)`, and the other MasonryGrid callers
  (`TagFeedView`, `AuthorContentGrid`, `UserContentView`) use the same cell — so one
  change to the grid media layer covers every grid.
- **Framing is already crash-safe.** `Self.displayAspectRatio(width:height:)` (added in
  `105ad50`) yields a finite, positive ratio; poster and player must share it so the
  hover swap causes no layout change.

## Scope

**In scope**

- Grid-mode video cells (`ImageFeedItemView.gridContent`) on both platforms.
- Default poster frame (from `thumbnailURL`) with the existing video badge; no `AVPlayer`
  created until needed.
- macOS: hover a video cell → inline muted, looping preview; un-hover → back to poster.
  Only the hovered cell plays.
- iOS: poster + tap opens the detail view (which plays, as today). No inline grid playback.

**Out of scope (YAGNI)**

- List mode (`listContent`) inline video — unchanged; separate follow-up if wanted.
- Sound in grid previews (previews stay muted; the detail view keeps sound).
- A global "currently playing" coordinator — per-cell hover state already guarantees one.
- Hover behavior on iOS (touch has no hover).
- Any change to detail-view playback.

## Design

### 1. Poster-by-default media layer (both platforms)

Replace the video branch of `gridContent`'s media with a `ZStack` whose base is always
the poster:

```
ZStack {
    CachedAsyncImage(url: image.thumbnailURL)   // always present, sized to the cell
        .aspectRatio(contentMode: .fill)
    // (macOS only) player overlay inserted here while hovering — see §2
}
```

The poster uses the same frame the player used (`geometry.size.width` ×
`width / displayAspectRatio`), so nothing reflows when the overlay appears. The existing
overlays (video badge, ellipsis, username, tap-to-open target) stay as they are. For
still images, the branch is unchanged.

### 2. macOS hover-to-play

- The cell tracks local `@State private var isHovering` via `.onHover`.
- Hover is filtered through a **~300 ms intent delay** (see §4): a quick pass-through does
  not start a load; a sustained hover does. Leaving cancels a pending start.
- Once intent fires, insert `CachedVideoPlayer(url: image.detailURL, autoPlay: true,
  isMuted: true)` as the top layer of the ZStack. Because the poster sits underneath, the
  player fades in over it and, on un-hover, is removed — its `.onDisappear` pauses the
  cached player (CachedVideoPlayer.swift:67-76). A safety `.onDisappear` on the cell also
  clears hover state so a video that scrolls away while hovered cannot keep playing.
- **No black flash:** `CachedVideoPlayer` gains a `showsLoadingPlaceholder: Bool = true`
  parameter. Hover previews pass `false`, making the `.idle`/`.loading` states render
  `Color.clear` instead of the black Rectangle+spinner, so the poster shows through until
  the first video frame is ready. Default `true` preserves current behavior everywhere else.
- Only the hovered cell has a player in the tree, so at most one video loads/plays. No
  coordinator.

### 3. iOS poster + tap

- No player is ever placed in the grid. The cell is the poster + badge + the existing
  `Color.clear` tap target that calls `openImageDetail()` (which sets `showingDetail`,
  presenting `ImageDetailView` that plays with sound).

### 4. Hover-intent model (the one testable unit)

Extract the debounce into a tiny, injectable-delay helper so it can be tested without real
time or SwiftUI:

```swift
struct HoverIntent {
    var delay: Duration = .milliseconds(300)
    // begin() starts a cancellable timer; if still hovering after `delay`, intent is armed.
    // cancel() disarms. Exposes whether intent is currently armed.
}
```

The cell owns one; `.onHover(true)` calls `begin`, `.onHover(false)` calls `cancel`, and
the armed flag gates inserting the player. Delay is injected so a test can use `.zero`.

### 5. Component extraction

Pull the grid media (poster base + platform-specific overlay/hover logic) into a small
`FeedGridMedia` subview that owns `isHovering`/`HoverIntent` and the poster/player choice.
`ImageFeedItemView.gridContent` keeps only its overlay chrome. This isolates the new state,
keeps the hover/`#if os(macOS)` logic in one focused place, and leaves `gridContent`
readable.

## Testing

- **Hover-intent unit test** (swift-testing, matching `FlowLayoutTests`/`ImageFeedItemAspectRatioTests`):
  with an injected `.zero` delay the intent arms; with a begin immediately followed by
  cancel it never arms. Confirms a quick sweep does not trigger playback while a sustained
  hover does.
- **Manual verification on both targets** (dual-target rule):
  - macOS: a video grid shows still posters at rest; hovering one plays only that one;
    moving away returns it to a poster; scrolling a hovered video away stops it. Confirm
    via `sample`/Activity Monitor that idle grids no longer spin up many
    `videomediaconverter` pipelines.
  - iOS: the grid shows posters with badges; tapping a video opens the detail view and it
    plays there; no inline grid playback.
- Regression: still-image cells and the crash-fix aspect-ratio test are unaffected.
