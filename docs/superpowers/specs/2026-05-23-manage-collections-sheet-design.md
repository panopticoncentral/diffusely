# Manage Collections Sheet — Design

**Date:** 2026-05-23
**Status:** Approved

## Goal

Replace the current one-shot "Add to Collection" flow with a NYT-Cooking-style
**Manage Collections** sheet: a single list of the user's collections with a
toggle per row showing membership. Flipping a toggle adds or removes the item
in real time. The same sheet also replaces today's per-item "Remove from this
collection" affordance inside `CollectionDetailView`.

## Background

Today, managing what collections an item belongs to requires juggling two
separate one-direction flows:

- **Adding**: `CollectionPickerView` is a sheet showing every user collection of
  the matching type. Tapping a row calls `addImageToCollection` /
  `addPostToCollection` and dismisses. There is no indication of whether the
  item is already in a given collection — tapping it twice silently
  re-adds/no-ops.
- **Removing**: only available from inside `CollectionDetailView`, via a
  context menu per item. Triggers a `confirmationDialog` and calls
  `removeImageFromCollection` / `removePostFromCollection`. There is no way to
  remove an item from a collection you are not currently viewing.

Six surfaces show "Add to Collection" today:

- `ImageDetailView`, `PostDetailView` (detail screens)
- `ImageFeedItemView`, `PostsFeedItemView` (feed cards)
- `AuthorContentGrid` (author profile content)
- `CollectionDetailView` per-item menu (currently "Remove from this collection")

Civitai's `collection.saveItem` tRPC procedure already accepts both
`collections` (additions) and `removeFromCollectionIds` (removals) in a single
call. The `collection.getUserCollectionItemsByItem` tRPC procedure (verified in
`CivitaiApi.md`) returns the list of the user's collections that contain a
given image or post, so membership is authoritatively answerable via API
without relying on local sync state.

## Source of Truth

Membership is fetched live from
`collection.getUserCollectionItemsByItem` each time the sheet opens. We do not
fall back to cached `PersistedCollection.images` / `posts` for the question
"is this item in this collection," because the cache is only authoritative for
collections that have been fully synced and silently lies (says "no") for
collections that have never been synced.

The local cache is still written through optimistically on every toggle so
that an open `CollectionDetailView` reflects the change immediately without a
re-sync — see "Cache Write-Through" below.

## UI

### Anatomy

```
┌─────────────────────────────────────────┐
│ Done                Manage Collections  │
├─────────────────────────────────────────┤
│ 📁⊕  New Collection…                   │
├─────────────────────────────────────────┤
│  My Favorites                       ◯─● │
│    A short description if present       │
├─────────────────────────────────────────┤
│  Inspiration                        ●─◯ │
├─────────────────────────────────────────┤
│  Contest Entries                    ◯─● │
│    ⚠ Couldn't update. Tap to retry.    │
└─────────────────────────────────────────┘
```

- Nav title: **"Manage Collections"**. Trailing toolbar is empty; the single
  action is **"Done"** in the leading (cancellation) slot.
- "New Collection…" row is always first, regardless of how many collections
  exist (so the empty state is one tap from un-empty).
- Each collection row shows name + optional one-line description (same as
  today's `CollectionPickerView` row), with a trailing SwiftUI `Toggle`.
- **Tap target is the toggle itself**; the row body is inert. This prevents
  accidental flips when the user just wants to read the description.
- Per-row errors render as a small caption-sized `exclamationmark.triangle.fill`
  label under the description. Tapping the label re-runs the failed flip.

### Ordering

Collections sort by **`PersistedCollection.listOrder`** when a cached row
exists (matching the order in `CollectionsView`). Any collection returned by
the API but absent from the local cache appends alphabetically at the end.

Collections created via the inline "New Collection…" row insert immediately
after the "New Collection…" row for the duration of the sheet so the user
sees the result of their action. Subsequent opens use whatever order the
cache has at that point.

### States

- **Loading**: centered `ProgressView` + "Loading collections…".
- **Loaded, empty**: centered `folder` icon + "No image/post collections found"
  + "Create one to add this image/post to it." The "New Collection…" row is
  still visible at the top.
- **Load failed**: centered `exclamationmark.triangle` + "Couldn't load
  collections" + a **Retry** button. No rows shown.
- **Per-row error**: see "Anatomy" above; row toggle reverts to original state.

### macOS sizing

Keep today's `frame(minWidth: 420, idealWidth: 480, minHeight: 420,
idealHeight: 560)` from `CollectionPickerView`.

### Entry-point gating

Menu item is shown only when `APIKeyManager.shared.hasAPIKey` is true (same
gate as today's "Add to Collection"). Inside `CollectionDetailView`, the
per-item context menu replaces "Remove from this collection" with **"Manage
Collections…"** (ellipsis hints at a follow-up sheet) and drops the
destructive styling.

The menu item icon changes from `folder.badge.plus` to **`folder`** — the
plus-badge is now misleading because the action is bidirectional.

## Architecture

### New files

**`Diffusely/Views/ManageCollectionsSheet.swift`** — the sheet view.

- Inputs: `target: ManageCollectionsTarget`, `onDismiss: () -> Void`.
- Owns: `@StateObject` for a `ManageCollectionsViewModel`, `@State` for the
  in-flight new-collection sheet presentation.

**`Diffusely/Services/ManageCollectionsViewModel.swift`** — `@MainActor`
`ObservableObject`.

- Fields:
  - `collections: [CivitaiCollection]`
  - `membership: Set<Int>` — collection IDs the item is currently in
  - `pendingFlips: Set<Int>` — collection IDs whose `saveItem` is in flight
  - `loadState: LoadState` — `.loading | .loaded | .failed(String)`
  - `rowErrors: [Int: String]`
- Methods:
  - `load() async` — issues `getUser{Image,Post}Collections` and
    `getUserCollectionItemsByItem` in parallel via `async let`.
  - `toggle(_ collection: CivitaiCollection)` — optimistic flip + cache
    write-through + `saveItem`; reverts on failure.
  - `addNewCollection(_ collection: CivitaiCollection)` — called after
    `CreateCollectionView` returns; appends to `collections`, marks
    membership, fires `saveItem` add, writes cache stub.
- Holds a `CivitaiService` and a `CollectionPersistenceService`, both
  injected via the initializer so tests can substitute fakes.

**`Diffusely/Models/ManageCollectionsTarget.swift`** — replaces today's
`CollectionItemType`:

```swift
enum ManageCollectionsTarget {
    case image(CivitaiImage)
    case post(CivitaiPost)

    var displayName: String { … }   // "image" / "post"
    var itemId: Int { … }
    var collectionType: String { … } // "Image" / "Post"
}
```

The target carries the full `CivitaiImage` / `CivitaiPost` (not just an id)
so the cache write-through can materialize a `Persisted*` row. Every existing
call site already has the full model in scope.

### Extended files

**`Diffusely/Services/CivitaiService.swift`**

- **New:** `func getUserCollectionItemsByItem(target: ManageCollectionsTarget)
  async throws -> [Int]` — POSTs to `collection.getUserCollectionItemsByItem`
  with `contributingOnly: true` and the matching `type`, decodes the array's
  `collectionId` fields.
- **New:** `func saveItem(target: ManageCollectionsTarget, adding: [Int],
  removing: [Int]) async throws` — single method replacing the four current
  one-direction methods. Constructs one `collection.saveItem` POST whose body
  includes both `collections` and `removeFromCollectionIds`.
- **Removed:** `addImageToCollection`, `removeImageFromCollection`,
  `addPostToCollection`, `removePostFromCollection`. All call sites migrate
  to `saveItem`.

**`Diffusely/Services/CollectionPersistenceService.swift`**

- **New:** `func addImageStub(_ image: CivitaiImage, toCollectionId: Int)` —
  inserts a `PersistedImage` for `image` tied to the collection if not
  already present, stamped with the collection's current `syncGeneration`.
- **New:** `func addPostStub(_ post: CivitaiPost, toCollectionId: Int)` —
  same shape, plus materializes `PersistedPostImage` children from
  `post.safeImages` (matching what `addPosts` does during sync).
- `removeImage(imageId:fromCollectionId:)` and
  `removePost(postId:fromCollectionId:)` already exist and are reused.

### Replaced / removed files

- **`Diffusely/Views/CollectionPickerView.swift`** — deleted. Its
  `CollectionItemType` enum moves to `ManageCollectionsTarget.swift` with the
  new shape (carries full model, not just id).
- **`CollectionDetailView`'s `pendingRemoval` confirmationDialog and the
  `performRemoval(_:)` private method** — deleted. The per-item "Remove from
  this collection" menu entry becomes "Manage Collections…" and presents the
  new sheet with the current collection already toggled on; the user flips it
  off to remove.

### Call-site changes

Each of the six entry points swaps:

```swift
// Before
showingCollectionPicker = true
…
.sheet(isPresented: $showingCollectionPicker) {
    CollectionPickerView(itemType: .image(id: image.id)) {
        showingCollectionPicker = false
    }
}
```

For:

```swift
// After
showingManageCollections = true
…
.sheet(isPresented: $showingManageCollections) {
    ManageCollectionsSheet(target: .image(image)) {
        showingManageCollections = false
    }
}
```

Menu labels change from "Add to Collection" to "Manage Collections" (without
the ellipsis on the menu item; the ellipsis appears only on
`CollectionDetailView`'s contextual menu version).

## Data Flow

### Opening

1. View appears → VM's `load()` fires.
2. Two parallel API calls via `async let`:
   - `getUser{Image,Post}Collections()` (existing)
   - `getUserCollectionItemsByItem(target:)` (new)
3. On success: populate `collections` and `membership`; sort per the
   ordering rules above.
4. On either failure: `loadState = .failed(…)`; render error/retry state.
5. While both are in flight: render the loading state.

### Toggling

1. User taps the row's toggle.
2. While the row's id is in `pendingFlips`, its toggle is rendered
   non-interactive (slightly dimmed, still showing the optimistic value).
   The user cannot tap it again until the in-flight `saveItem` resolves.
3. On a fresh tap, VM:
   - Inserts the id into `pendingFlips`.
   - Optimistically mutates `membership` (insert or remove).
   - Writes through to the local cache:
     - **on**: `addImageStub(image, toCollectionId:)` or
       `addPostStub(post, toCollectionId:)`.
     - **off**: `removeImage(imageId:, fromCollectionId:)` or
       `removePost(postId:, fromCollectionId:)`.
   - Calls `saveItem(target:, adding:, removing:)` with the changed id in
     the appropriate array and the other array empty.
4. On success: remove from `pendingFlips`, clear any previous
   `rowErrors[id]`.
5. On failure: revert `membership`, revert the cache mutation (re-insert
   the stub if we removed, delete it if we added), set `rowErrors[id]`,
   remove from `pendingFlips`.

### Creating a new collection inline

1. User taps the "New Collection…" row.
2. Sheet presents the existing `CreateCollectionView` modally over itself.
3. On successful create, `CreateCollectionView` returns the new
   `CivitaiCollection` to the VM via callback.
4. VM:
   - Calls `persistenceService.getOrCreateCollection(from:)` to ensure a
     `PersistedCollection` row exists.
   - Inserts the new collection into `collections` immediately after the
     "New Collection…" row.
   - Optimistically inserts its id into `membership` and writes the cache
     stub.
   - Calls `saveItem(target:, adding: [newId], removing: [])`.
5. On `saveItem` failure: delete the cache stub, remove from `membership`,
   show inline row error. The collection itself stays in the list (it was
   really created server-side).

### Dismissing

- "Done" is purely a dismiss action; there is no "Save"/"Cancel" semantics
  because toggles are already persisted.
- In-flight `saveItem` tasks are **not** cancelled on dismiss. They complete
  against the local cache. Any failure that happens after dismiss is logged
  but cannot be surfaced to the user; the cache will reflect the failed
  state, and the next open of the sheet for this item will re-fetch
  membership and show truth.

## Cache Write-Through

The optimistic write reflects in `CollectionDetailView` instantly without
waiting for a re-sync. Two reasons this is safe with the existing
mark-and-sweep sync model:

- **Fresh full pass in progress** (`syncCursor == nil` at pass start): the
  generation was bumped at pass start; our stub's `lastSeenGeneration`
  matches it, so the sync's sweep will preserve our row.
- **Mid-pass / resuming pass**: generation is whatever the collection has
  right now; we read it at the moment of the write, so they match.

Known small hazard: a sync that has already paged past a position where the
item *would* appear, while a user-driven *remove* happens, may briefly
re-insert a stale row at the next page boundary. We do not attempt to
coordinate; the next sync corrects it. Acceptable.

`addPostStub` builds child `PersistedPostImage` rows from `post.safeImages`
just like `addPosts` does during sync, so the stubbed row is visually
indistinguishable from a sync-inserted row.

## Error Handling & Edge Cases

- **Either fetch fails on open**: whole sheet shows the error/retry state.
  We do not render a half-broken list, because showing collections without
  knowing membership invites the user to flip toggles that already reflect
  server state.
- **Per-toggle failures**: each row independently surfaces its own inline
  error; no global error banner.
- **Rapid double-tap on the same toggle**: second tap is dropped while the
  first is in flight (key off `pendingFlips`). No request cancellation.
- **Dismiss mid-flight**: tasks complete in the background against the
  cache; failures after dismiss are silent. Next open shows truth.
- **No API key at open time**: cannot happen in practice (entry points are
  gated); VM defensively maps `URLError.userAuthenticationRequired` to
  "Sign in to manage collections."
- **`contributingOnly: true`**: passed to both `getAllUser` and
  `getUserCollectionItemsByItem` so the two views stay consistent — we
  never show membership for a collection that isn't in the list.

## Testing

### Extended

**`MultiCollectionMembershipTests.swift`** — add cases for `addPostStub` /
`addImageStub`:

- Stub against a collection that doesn't yet have the item → new row,
  correct `lastSeenGeneration`.
- Stub against a collection that already has the item → idempotent (no
  duplicate row).
- Stub followed by `removeImage` / `removePost` → row gone; the other
  collection's row for the same item is untouched.

### New

**`DiffuselyTests/ManageCollectionsViewModelTests.swift`** — pure VM tests
with a fake `CivitaiService` protocol and an in-memory
`CollectionPersistenceService`:

- `load()` populates state from parallel fetches; ordering follows
  `listOrder` then alphabetical.
- `load()` failure on either call → `loadState == .failed`.
- `toggle(on)` for an unchecked row: optimistic update, cache stub inserted,
  `saveItem` called with `adding: [id], removing: []`, success clears
  pending.
- `toggle(off)` mirror.
- `toggle` failure: state reverts, cache mutation reverts, `rowErrors[id]`
  set, `pendingFlips` cleared.
- Rapid double-tap: second tap dropped, no duplicate `saveItem`.
- `addNewCollection`: collection appears in list, `membership` includes it,
  `saveItem` called, cache stub inserted; on failure the collection stays
  in the list but is not in `membership`.

**`DiffuselyTests/CivitaiServiceManageCollectionsTests.swift`** — request
shape tests for the new/changed service methods. Asserts the encoded tRPC
body for:

- `getUserCollectionItemsByItem` with `imageId`.
- `getUserCollectionItemsByItem` with `postId`.
- `saveItem` with both `collections` (non-empty) and
  `removeFromCollectionIds` (non-empty) in one call, proving we use the
  batched form.

### Service-method-collapse migration

Any existing tests exercising `addImageToCollection` /
`removeImageFromCollection` / `addPostToCollection` /
`removePostFromCollection` get migrated to assert against `saveItem` with
the appropriate `adding` / `removing` argument, preserving coverage of the
request shape.

### Not tested

- SwiftUI rendering of the sheet itself; no view-snapshot infrastructure in
  the project.
- `CreateCollectionView` integration; covered by `CreateCollectionTests`.

### Manual smoke-test checklist (for PR description)

1. Add a single new collection from inline "New Collection…" while item is
   in zero collections.
2. Toggle on then off rapidly on the same collection.
3. Toggle on a collection while offline → row error, toggle reverts.
4. Open on an item already in 3 of 5 collections → 3 toggles on, 2 off.
5. Open from inside `CollectionDetailView`'s per-item menu → current
   collection's toggle is on; flipping it off removes from the visible
   grid.
6. macOS: window sizing matches the old picker.
