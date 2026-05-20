# Library Sort & Grouping — Design

**Date:** 2026-05-20
**Status:** Approved (pending written-spec review)

## Context

`LibraryView` today shows a flat `MasonryGrid` driven by a single
`@Query(sort: \PersistedLibraryItem.savedAt, order: .reverse)`. There is no way
to sort by anything else and no grouping. We recently shipped sort + grouping
for `CollectionDetailView` (`CollectionSort`: Author A–Z/Z–A grouped, Date
Newest/Oldest flat) with pinned section headers, expand/collapse state, and a
one-shot publish-date backfill for items that predate date support. The user
wants the same affordance for the library, extended with **group-by-checkpoint**.

Constraints discovered during exploration:

- `PersistedLibraryItem` (the disposable SwiftData index) stores
  `savedAt`, `authorUsername`, `mediaType`, `width/height`, `fileByteSize`,
  `downloadStatus`. **No publish date, no author avatar, no checkpoint.**
- The sidecar JSON (`LibraryItemMetadata`, currently schema v2) has the author
  block (with `avatarURL`) and `generationData.resources`, but **does not yet
  record the original publish date** of the source image.
- `CivitaiImage` exposes `publishedAt: String?` and a parsed
  `publishedAtDate: Date?`, so the field is available at save time and via a
  re-fetch.

## Goal

Add sort/group to `LibraryView` mirroring the collection-view pattern:

- 6 sort options: Date Newest/Oldest (flat), Author A–Z/Z–A (grouped),
  Checkpoint A–Z/Z–A (grouped).
- "Date" = **original publish date**, not the local save date.
- Within author and checkpoint groups, items are **always newest-first by
  publish date** (not configurable).
- For checkpoint sorts, items with no checkpoint fall into fixed-order
  fallback buckets at the tail: **"Videos"** then **"Other"**.
- Author headers show the same `AuthorSectionHeader` (with avatar) used by the
  collection view; checkpoint and media-bucket headers reuse the same visual
  shape with a different leading icon.
- Sort selection is in-memory `@State` only (no persistence across launches),
  matching `CollectionDetailView`.

## Non-goals

- Sort by file size, group by media type, group by download status. Explicitly
  cut for YAGNI — easy to add later.
- A configurable secondary order inside groups.
- Persisting selected sort to `UserDefaults` / `@AppStorage`.
- Backfilling publish dates ahead of time at app launch — only on demand when
  a date-sensitive sort is active.

## Approach

**Mirror `CollectionSort` exactly; denormalize new fields into the index.**
This is the same shape as the collection-view feature: the new sort lives in
a small enum, a service helper computes sorted/grouped content from indexed
columns, and the view consumes a `flat / grouped` sum type. Alternatives
considered and rejected:

- **In-memory sort by reading every sidecar JSON on each reload.** No schema
  changes, but does scaling I/O on every sort change and reconcile. Slow at
  library sizes that masonry prefetch already strains.
- **Hybrid (denormalize cheap keys, compute checkpoint lazily from sidecar).**
  Adds a third code path with no real upside.

## Data model changes

### Sidecar JSON — schema v3

```swift
// LibraryItemMetadata
static let currentSchemaVersion = 3
let publishedAt: Date?   // NEW — original Civitai publish date, nullable
```

`publishedAt` decodes as `nil` for v2 sidecars — no breaking change to existing
files, decoder handles missing keys via optional. `LibrarySaveService` writes
`image.publishedAtDate` into this field on save.

### `PersistedLibraryItem` — three new columns

```swift
var publishedAt: Date?
var authorAvatarURL: String?
var checkpointName: String?
```

All optional. The index is disposable (rebuilt from sidecars by
`LibraryIndexService.reconcile`) so there is no SwiftData migration step
beyond adding the properties.

`PersistedLibraryItem.init(metadata:)` denormalizes:

- `publishedAt = metadata.publishedAt`
- `authorAvatarURL = metadata.author.avatarURL`
- `checkpointName = metadata.generationData?.resources?
                       .first { $0.modelType == "Checkpoint" }?.modelName`

(First `Checkpoint`-typed resource wins; the modelType string match is
exact and case-sensitive — that is what the Civitai API emits.)

### Publish-date backfill

For items saved before v3 (sidecars with `publishedAt == nil`):

- `CivitaiService` does not currently have a single-image-by-id fetch
  (`fetchImages` is bulk and writes to a published array). Add a new
  `func fetchImage(imageId: Int) async throws -> CivitaiImage` that hits
  `/api/v1/images?imageId=N&limit=1` and returns the first hit (or throws
  not-found). This is the smallest viable addition and stays consistent
  with `fetchGenerationData(imageId:)`'s shape.
- A new `LibraryDateBackfillService` calls `fetchImage(imageId:)`, pulls
  `publishedAt` (and any other freshened sidecar fields it cheaply can —
  `stats`, `nsfwLevel`), rewrites the sidecar with `schemaVersion = 3`,
  and updates the index row.
- One request at a time (serial), to avoid hammering the API. No retry/backoff
  beyond what the existing `CivitaiService` does — failures just leave that
  item's `publishedAt` as `nil` and move on.
- Trigger: in `LibraryView`, when the active sort is date-sensitive (any of
  the six — date and within-group ordering all use `publishedAt`) **and** at
  least one indexed item has `publishedAt == nil`, kick off backfill once per
  view instance (guarded by `didRequestDateBackfill: Bool`). Mirrors
  `CollectionDetailView`'s flag exactly.
- UI affordance: a subtle inline strip at the top of the grid
  ("Backfilling publish dates… N remaining") while running. Disappears when
  the queue empties.

Backfill is best-effort and never blocks the UI; items missing `publishedAt`
remain visible — they just sink to the bottom of date-ordered lists.

## Sort model

```swift
enum LibrarySort: String, CaseIterable, Identifiable, Equatable {
    case dateNewest           = "Date (Newest)"
    case dateOldest           = "Date (Oldest)"
    case authorAscending      = "Author (A–Z)"
    case authorDescending     = "Author (Z–A)"
    case checkpointAscending  = "Checkpoint (A–Z)"
    case checkpointDescending = "Checkpoint (Z–A)"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var isAuthorGrouped: Bool { self == .authorAscending || self == .authorDescending }
    var isCheckpointGrouped: Bool { self == .checkpointAscending || self == .checkpointDescending }
    var isGrouped: Bool { isAuthorGrouped || isCheckpointGrouped }

    var ascending: Bool {
        switch self {
        case .dateNewest, .authorDescending, .checkpointDescending: return false
        case .dateOldest, .authorAscending, .checkpointAscending:   return true
        }
    }

    var icon: String { /* arrow.up/down + clock/calendar/cube.transparent */ }
}
```

Same idiom as `CollectionSort`. Default is `.dateNewest`.

## Sorted-content service

A new helper — most naturally a method on `LibraryIndexService` so it shares
the model context, or a small `LibrarySortService` if the index service grows
unwieldy. Mirrors `CollectionPersistenceService.getSortedContent`:

```swift
enum LibrarySortedContent {
    case flat([PersistedLibraryItem])
    case grouped([LibraryGroup])
}

struct LibraryGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case author(username: String, avatarURL: String?)
        case checkpoint(name: String)
        case bucket(Bucket)              // unbucketed-by-checkpoint fallback
    }
    enum Bucket: Equatable { case videos, other }
    let id: String
    let kind: Kind
    let items: [PersistedLibraryItem]
}

@MainActor
func sortedLibraryContent(sort: LibrarySort) -> LibrarySortedContent
```

Rules:

- **Date sorts** → `.flat(items)`, ordered by `publishedAt`. Items with
  `publishedAt == nil` sink to the tail regardless of direction (stable
  ordering by `itemID` desc as a tie-breaker).
- **Author sorts** → `.grouped(groups)` keyed by `authorUsername`
  (case-insensitive compare for ordering; preserve original casing in the
  display name). Items with no username go into a single "Unknown" group
  placed at the tail in both directions. Each group's `items` are sorted
  newest-first by `publishedAt` with the same nil-sink/`itemID` tie-break.
  `id` = `"author:" + lowercased(username)` (or `"author:__unknown__"`).
- **Checkpoint sorts** → `.grouped(groups)` keyed by `checkpointName`. Items
  with no `checkpointName` are routed by `mediaType`:
  - `video` → "Videos" bucket
  - `image` → "Other" bucket
  Bucket groups always appear after the named ones, in fixed order
  (Videos before Other), regardless of asc/desc. `id` = `"checkpoint:" + name`
  or `"bucket:videos"` / `"bucket:other"`. Each group's `items` are again
  newest-first by `publishedAt`.

The view stays dumb — it just consumes `LibrarySortedContent`.

## View structure

`LibraryView` shifts from a `@Query`-bound list to the same pattern as
`CollectionDetailView`:

```swift
@State private var selectedSort: LibrarySort = .dateNewest
@State private var content: LibrarySortedContent = .flat([])
@State private var expandedGroups: Set<String> = []     // keyed by LibraryGroup.id
@State private var didRequestDateBackfill = false
@State private var isInitialLoad = true
```

- `.task` and a notification-triggered reload (the existing reconcile signal)
  call a `reloadContent()` that calls the sorted-content service.
- `.onChange(of: selectedSort)` triggers `reloadContent()`.
- Toolbar gets a `LibrarySortMenu` — a sibling of `CollectionSortMenu`,
  taking `@Binding var selectedSort: LibrarySort`. Same visual treatment
  (`arrow.up.arrow.down.circle` label).

Rendering:

- **Flat** → existing `MasonryGrid(items:aspectRatio:)` over the items.
  No change.
- **Grouped** → `LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders])` of
  `Section { groupBody } header: { groupHeader }`, where `groupBody` is the
  same `MasonryGrid` over `group.items` and the header depends on kind:
  - `.author` → reuse `AuthorSectionHeader`. Pass a synthesized `CivitaiUser`
    (`id` from a deterministic hash of the username, `username`, `image =
    avatarURL`).
  - `.checkpoint` → new lightweight `LibraryGroupHeader` view sharing the
    layout (icon + title + count + chevron) using a `cube.transparent` icon.
  - `.bucket(.videos)` → same header view, `film` icon, title "Videos".
  - `.bucket(.other)` → same header view, `photo.stack` icon, title "Other".

  Expansion state behavior — straight port from the collection:
  - On `isInitialLoad`, all group ids are added to `expandedGroups`.
  - On subsequent reloads, preserve existing state and add only the
    newly-seen ids.

- Footer count text (`itemCountText`) stays where it is.
- Empty-state and iCloud-unavailable banner unchanged.

The `@Query` on `LibraryView` is removed; data flows in through
`reloadContent()` which the service can query directly (fetch all items,
group, sort). For a library of plausible sizes (low thousands), in-memory
group/sort on each reload is fine — same as the collection-view does.

## Testing

A new `LibrarySortTests.swift` covering:

- **Flat date sorts** — `publishedAt: nil` items sink to the tail in both
  directions; `itemID` is the stable tie-breaker.
- **Author asc/desc** — section order, case-insensitive grouping (e.g.
  `"Alice"` and `"alice"` collapse), "Unknown" group always at the tail.
- **Checkpoint asc/desc** — section order; "Videos" bucket holds videos
  without checkpoint, "Other" holds images without checkpoint; both always
  at the tail and Videos always before Other regardless of direction.
- **Within-group order** — newest-first by `publishedAt` regardless of the
  outer asc/desc direction.
- **First-Checkpoint-resource-wins** for `checkpointName` derivation (a unit
  test on `PersistedLibraryItem.init(metadata:)`).

Existing `LibraryTests.swift` — if it asserts on `@Query` ordering or the
flat shape, update those assertions to go through the new sorted-content
service.

The publish-date backfill service gets its own minimal coverage: a fake
`civitaiService` that returns a canned image, verify the sidecar is rewritten
to v3 and the index row's `publishedAt` is populated. No need to exercise
the rate limiter beyond confirming serial dispatch.

## Files touched (rough map)

- `Models/Library/LibrarySort.swift` *(new)*
- `Models/LibraryItemMetadata.swift` — bump `currentSchemaVersion` to 3, add
  `publishedAt: Date?`
- `Models/Persistence/PersistedLibraryItem.swift` — three new optional
  properties + denormalization in `init(metadata:)`
- `Services/LibrarySaveService.swift` — write `publishedAt` into sidecar
- `Services/LibraryIndexService.swift` — `sortedLibraryContent(sort:)` method;
  reconcile already repopulates the index from sidecars so the new columns
  fill in for free
- `Services/CivitaiService.swift` — add `fetchImage(imageId:)`
- `Services/LibraryDateBackfillService.swift` *(new)*
- `Views/LibrarySortMenu.swift` *(new)*
- `Views/LibraryGroupHeader.swift` *(new — for checkpoint/bucket groups)*
- `Views/LibraryView.swift` — drop `@Query`, add sort/group state and
  rendering branches
- `DiffuselyTests/LibrarySortTests.swift` *(new)*
- `DiffuselyTests/LibraryTests.swift` — adjust if needed
