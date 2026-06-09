# Library Multi-Select & Delete — Design

**Date:** 2026-06-08
**Status:** Approved (design)

## Goal

Let the user select multiple items in the Library grid and delete them in one
action, without leaving the Library view. Single-item deletion already exists
via `LibraryDetailView` → `LibraryStore.remove(itemID:)`; this adds a batch path
and the selection UI in the grid.

## Scope (and non-goals)

In scope:
- A toolbar **"Select"** button to enter selection mode.
- Tap-to-toggle selection on grid cells, with a checkmark badge.
- A live **"N Selected"** count in the navigation title.
- A **trash** action with a confirmation dialog showing the count.
- A batch `LibraryStore.remove(itemIDs:)` method.

Out of scope (YAGNI for this pass):
- Select All / Deselect All.
- Long-press to enter selection mode.
- Any non-delete batch action (share, export, move, etc.).

## Approach

Selection is pure view state, so it lives in `LibraryView` as `@State` —
matching the existing `expandedGroups` / `selectedSort` pattern. It does not need
to survive tab switches or iCloud sync, so there is no reason to push it into
`LibraryStore`. The store gains exactly one new method: a batch delete.

## Changes

### `LibraryView` state

```swift
@State private var isSelecting = false
@State private var selectedIDs: Set<Int> = []          // keyed by item.itemID
@State private var showingBulkDeleteConfirm = false
```

### Cell behavior (`cells(for:)`)

- **Not selecting** → `NavigationLink` to `LibraryDetailView` (unchanged).
- **Selecting** → plain `Button` that toggles `item.itemID` in `selectedIDs`.
  A checkmark badge overlays a corner of the thumbnail
  (`checkmark.circle.fill` when selected, `circle` when not), and selected
  cells dim slightly. Reuses the existing `thumbnail(for:)` view with an added
  overlay; no change to thumbnail rendering itself.

### Toolbar

- **Not selecting:** existing sort menu + a new **"Select"** button.
- **Selecting:** **"Done"** (exits selection mode, clears `selectedIDs`) and a
  **trash** button (disabled when `selectedIDs` is empty). The sort menu is
  hidden while selecting. Navigation title shows **"N Selected"**, or
  **"Select Items"** when nothing is selected.

Toolbar placement is handled cross-platform (the project builds for iOS/iPadOS
and macOS): leading/trailing on iOS, appropriate placements on macOS, following
the conventions already used elsewhere in the view.

### Delete flow

1. Trash button → `confirmationDialog` titled *"Delete N items?"* with message
   *"This deletes your saved copies and their metadata from iCloud."* — mirrors
   the single-item wording in `LibraryDetailView`.
2. On confirm → `await store.remove(itemIDs: Array(selectedIDs))`.
3. Clear `selectedIDs`, set `isSelecting = false`. The existing
   `onChange(of: store.itemCount)` reloads the grid content.

### `LibraryStore.remove(itemIDs:)`

```swift
func remove(itemIDs: [Int]) async
```

Behavior, designed to avoid the redundant work of calling `remove(itemID:)` in
a loop:

- Resolve the items directory **once** (not per item).
- For each id, coordinate file deletion of `{id}.json`, `{id}.jpeg`,
  `{id}.mp4` (skipping files that don't exist) and call
  `indexService.remove(itemID:)`.
- Call `refreshTotals()` **once** at the end (not per item).

The existing single-item `remove(itemID:)` is retained unchanged for
`LibraryDetailView`.

## Grouped view

Selection is keyed by `itemID`, so it is independent of grouping and sort.
Items in collapsed sections are simply not on screen to tap. The selection set
persists across expand/collapse and re-sort. No change to grouping logic.

## Testing

- Unit-test `LibraryStore.remove(itemIDs:)` in the existing `LibraryTests`
  suite: deletes the files and index entries for all listed ids, leaves
  unlisted items intact, and refreshes totals once.
- Selection toggling is trivial view state and is not separately unit-tested.

## Risks

- Deletion removes the user's iCloud copies and is not undoable — the
  confirmation dialog with an explicit count is the guard.
- Bulk deleting many items issues many file-coordination operations; doing them
  within a single `remove(itemIDs:)` call (one directory resolve, one totals
  refresh) keeps overhead proportional to file count, not multiplied by it.
