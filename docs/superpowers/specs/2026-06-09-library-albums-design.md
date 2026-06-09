# Library Albums — Design

**Date:** 2026-06-09
**Status:** Approved, ready for implementation planning

## Summary

Add albums to the personal Library. Users can place photos/videos — individually or
via multi-select — into a new or existing album. An album opens to the same grid the
Library uses today, with the full set of sort/group options. A built-in **"Not in any
Album"** smart view shows every item that belongs to zero albums, also with full
sort/group support.

Membership is **many-to-many**: an item can belong to multiple albums at once (Apple
Photos model). An item appears in "Not in any Album" only when it is in zero albums.

## Goals

- Create albums and add items (single item or multi-select) to a new or existing album.
- Open an album to a grid scoped to that album's items, reusing every existing
  sort/group option and Select mode.
- A built-in "Not in any Album" smart album with the same grid + sort/group.
- Manage albums: remove items from an album, rename an album, delete an album.

## Non-Goals (v1)

- Manual album cover selection. Cover auto-uses the album's most recent member.
- Manual ordering of items within an album. Albums reuse `LibrarySort`; there is no
  custom per-album order.
- Nested albums / folders.
- Deleting the underlying photos when deleting an album. Deleting an album never
  deletes media.

## Architectural Constraint

The Library's invariant: **the sidecar JSON in the iCloud container is the source of
truth; the SwiftData index (`PersistedLibraryItem`) is disposable and fully rebuilt
from the sidecars by reconcile.** Albums must store their durable state in the
container so they survive an index rebuild and sync across devices. The SwiftData
layer is only a queryable cache.

## 1. Storage Model (decision: item-side membership)

Album membership lives **on each item's sidecar**; albums carry only their own
identity/name in a separate metadata file.

- **Item sidecar (`{itemID}.json`), schema v5** — adds `albumIDs: [String]` (album
  UUID strings). Sidecars older than v5 decode with an empty array.
- **Album metadata file (`album-{uuid}.json`)** — `{ id: String (UUID), name: String,
  createdAt: Date }`. This file is the album's existence record; it lets an empty
  album exist and carries the rename target. It does **not** list members.

### Why item-side (Option 1) over album-side (Option 2)

| Concern | Option 1 (item-side, chosen) | Option 2 (album-side) |
|---|---|---|
| Add N items to an album | Rewrite those N item sidecars | Read-modify-write one album file |
| Two devices add different items concurrently | Conflict-free (distinct files) | Race on one file → lost membership |
| "Not in any Album" | `item.albumIDs ∩ knownAlbums == ∅` — per-item filter | Union all album memberIDs, then subtract |
| Reuse existing sort/group | Pre-filter item set → feed `LibrarySortService` unchanged | Same, but membership lookup is indirect |

Option 1 spreads writes across item files (no hot-spot, conflict-free multi-select
adds) and makes "Not in any Album, with all sort/group options" nearly free: it is
just a filtered item set handed to the existing `LibrarySortService`.

## 2. Data Model & Services

- **`PersistedAlbum` (`@Model`)** — disposable index row: `id: UUID`, `name: String`,
  `createdAt: Date`. Rebuilt from `album-*.json` during reconcile, exactly like
  `PersistedLibraryItem` is rebuilt from item sidecars. No relationships to other
  SwiftData models (same isolation discipline as `PersistedLibraryItem`).
- **`PersistedLibraryItem`** gains `albumIDsJoined: String` — a denormalized,
  delimiter-joined list of the item's album UUIDs, parsed to a `Set<String>` for
  filtering. This matches the existing `fetchAll()` + in-memory filter style rather
  than fighting SwiftData over array-membership predicates. Populated from the
  sidecar's `albumIDs` by `PersistedLibraryItem(metadata:downloadStatus:)`.
- **Sidecar `LibraryItemMetadata`** — `currentSchemaVersion = 5`; add `albumIDs:
  [String]` with a memberwise-init default of `[]` (same source-compatible pattern
  used for the v4 `publishedAtBackfillAttemptedAt` field). Include `albumIDs` in
  `LibraryItemMetadata.==` so a membership change registers as a real change to the
  index (drives re-ingest).
- **`LibraryAlbumService`** — owns all album mutations:
  - `createAlbum(name:) -> UUID` — writes `album-{uuid}.json`.
  - `renameAlbum(id:to:)` — rewrites that album file only.
  - `deleteAlbum(id:)` — coordinated delete of `album-{uuid}.json`.
  - `addItems(_:toAlbum:)` — rewrites each affected item sidecar, appending the album
    UUID to `albumIDs`.
  - `removeItems(_:fromAlbum:)` — rewrites each affected item sidecar, dropping the
    UUID.
  - All file writes (and the album-file delete) go through the existing
    **`deleteQueue` / `NSFileCoordinator` discipline** used by `LibraryStore` — the
    synchronous coordinated file I/O must stay off the Swift concurrency cooperative
    pool (the documented grey-spinner / cooperative-pool-starvation regression).
- **Reconcile** branches on filename: `{int}.json` → item sidecar (today's path);
  `album-{uuid}.json` → album metadata → upsert `PersistedAlbum`. Both already match
  the `*.json` `NSMetadataQuery` predicate, so an album edit on another device
  triggers a reconcile with no new observer.
- **Read side** — `LibrarySortService` (or a thin wrapper) accepts an optional item
  filter: a specific album's members (`albumIDsJoined` contains the UUID), or the
  "not in any album" complement (`albumIDs ∩ knownAlbumIDs == ∅`). The filtered set
  flows through the existing sort/group code unchanged.

## 3. UI & Interaction (Layout B: Photos / Albums switch)

- **Library toolbar** gains a segmented **Photos / Albums** control.
  - *Photos* — today's flat grid, unchanged.
  - *Albums* — a 2-up grid of album cover tiles (auto-cover = most recent member),
    plus a **"Not in any Album"** smart tile and a **New Album** tile.
- **Tapping an album** pushes a screen that is the existing Library grid scoped to
  that album's items — same Sort menu, same grouping, same Select mode. **"Not in any
  Album"** pushes the identical screen over the complement set.
- **Add to album** — the existing multi-select toolbar and the single-item context
  menu gain **"Add to Album…"** → a sheet listing existing albums + "New Album…".
  Sits next to the current bulk-delete action.
- **Inside an album**, Select mode gains **"Remove from Album"** beside Delete.
  Album-level **Rename** and **Delete Album** live in an overflow menu on the album
  screen.

## 4. Edge Cases

- **Delete album** removes only `album-{uuid}.json`. Member items keep the now-dangling
  UUID in their sidecar indefinitely; there is no active cleanup. The id is tolerated
  at rest and filtered out against the known-album set at read time. Photos are never
  touched.
- **Dangling album ID** (album deleted on another device, item still references it) →
  the item reads as "not in that album"; no crash, no orphan UI.
- **Empty album** is valid and listed (its existence comes from the album file, not
  from any member).
- **Album cover** with no members → placeholder tile; otherwise the most recent
  member's thumbnail.
- **iCloud unavailable** — albums behave exactly like items today (local-only, same
  banner). No special handling.

## 5. Testing

Mirror the existing `LibrarySortTests` / `LibraryTests` / `LibraryFileMaterializerTests`
style (services are directory-injected and unit-testable against a temp directory,
no iCloud container):

- Sidecar v5 round-trips `albumIDs`; v4-and-earlier sidecars decode to `[]`.
- `LibraryAlbumService`: create / rename / delete album, add / remove items — each
  asserted against on-disk files in a temp directory.
- Reconcile rebuilds `PersistedAlbum` rows and item membership from files.
- "Not in any Album" returns exactly the complement of the union of album members.
- Dangling-ID filtering: an item referencing a deleted album is excluded from that
  album and counted as "not in any album" when it has no other album.
- Filtered sort/group: an album's member set and the complement set both flow through
  every `LibrarySort` case correctly.

## Open Questions

None. Custom cover and manual ordering are explicitly deferred (see Non-Goals).
