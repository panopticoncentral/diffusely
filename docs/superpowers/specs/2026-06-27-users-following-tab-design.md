# Users (Following) Tab

**Date:** 2026-06-27
**Status:** Approved design, ready for implementation plan

## Problem

The app can already follow and unfollow individual creators, but there is no way to
see the list of people you follow in one place. To revisit a creator you have to
stumble across one of their images again. We want a top-level **Users** tab that lists
the creators you follow and lets you jump straight to any of their content.

## Key findings (verified against current code and Civitai source)

- **Follow plumbing already exists.** `CivitaiService.getFollowingUserIds()` fetches the
  follow list and `toggleFollowUser(targetUserId:)` follows/unfollows. `UserContentView`
  is a ready-made destination showing a single creator's images/videos with a
  Follow/Following button.
- **The follow list is IDs only.** `user.getFollowingUsers` (Civitai `getUserFollows`)
  returns a bare array of user IDs — no usernames or avatars. Confirmed in the Civitai
  source (`src/server/redis/caches.ts` → `follows: number[]`). To render a useful list we
  must resolve each ID to a profile.
- **`user.getById` resolves a single ID.** Public tRPC procedure returning
  `{ id, username, image, deletedAt, profilePicture }` (`simpleUserSelect`). This gives
  everything a row needs.
- **`PersistedAuthor` already caches profiles.** SwiftData model with `id`, `username`,
  `imageURL`, populated as you browse feeds. Many followed creators are likely already
  cached, so we can hydrate instantly and only fetch the gaps.
- **Navigation patterns are fixed by precedent.** Every iOS caller opens `UserContentView`
  via `fullScreenCover(item:)`; macOS pushes through `FeedNavigator` +
  `navigationDestination(item: $feedNavigator.user)`. The Users tab follows the same
  patterns rather than inventing new ones.
- **iPhone tab limit.** iOS shows only 5 tabs before collapsing the rest into a "More"
  menu. The app is already at 5 (Images, Videos, Collections, Library, Settings). To keep
  all primary tabs visible we relocate Settings off the tab bar (decision below).

## Scope

**In scope**

- A top-level **Users** tab (iOS) / **Users** sidebar section (macOS) listing followed
  creators as rows (avatar + username), in the order the API returns them.
- Tapping a row opens that creator's existing `UserContentView`.
- Resolving follow IDs to display profiles: cache-first from `PersistedAuthor`, lazy
  fetch of gaps via `user.getById`, upserting results back into the cache.
- Relocating Settings off the iPhone tab bar to a **gear button on the feed header**
  (Images & Videos), presented as a sheet.
- States: no API key, loading, empty (following nobody), error + retry, loaded.
- Pull-to-refresh.

**Out of scope (YAGNI / deferred)**

- Inline unfollow from the list (swipe / context menu). v1 is view-only; unfollow happens
  in `UserContentView`, which already has the button.
- Alphabetical or any non-API sort. Preserve API order so rows render immediately without
  waiting on resolution.
- User search / discovery of creators you don't already follow.
- A grid layout. v1 is a rows list (chosen over grid).
- Showing follower/following counts, bios, or other profile metadata in the row.

## Decisions (from brainstorming)

- **Tab placement:** Users is a real top-level tab; Settings is relocated off the iPhone
  tab bar so all 5 primary tabs stay visible. (macOS already keeps Settings in the app
  menu — no change there. iPad sidebar has room.)
- **Settings access:** a gear button on the main feed header (Images/Videos), one tap from
  the default landing tab.
- **List layout:** rows (avatar + username), not a grid.
- **Unfollow:** detail-screen only for v1.
- **Resolution strategy:** cache-first + lazy resolve (Approach A below).

## Resolution strategy (the one real engineering choice)

**Chosen — A: cache-first + lazy resolve.** Render one row per follow ID immediately, in
API order. Hydrate names/avatars instantly from `PersistedAuthor`; for uncached IDs, fetch
`user.getById` lazily as rows scroll into view (bounded concurrency), and upsert results
back into `PersistedAuthor`. Responsive, bounded work, scales to large follow lists, and
warms the shared cache.

Rejected:
- **B: eager batch** — fetch every profile up front behind a spinner. Allows alpha sort but
  is slow/heavy for large follow lists and has worse perceived performance.
- **C: resolve on tap** — minimal rows with no names/avatars until tapped. Trivial but not
  the experience we want.

## Components

Each unit has one purpose, a clear interface, and is independently testable.

### `CivitaiService.fetchUser(id:)` — new method

- **Does:** GET `user.getById` with tRPC input `{ id }`, decodes
  `{ id, username, image, profilePicture, deletedAt }`, returns a `CivitaiUser`
  (mapping `image` to the avatar field). Returns nil / throws a recognizable "not found"
  for deleted users so the store can hide them.
- **Depends on:** existing `session`, `baseURL`/`accountBaseURL`, tRPC decode helpers.
- **Auth:** public procedure; works with or without an API key (we send the key when
  present, as elsewhere).

### `FollowingStore` — new `@MainActor ObservableObject`

- **Does:** the data engine behind the tab.
  - `load()` / `refresh()`: call `getFollowingUserIds()` → `[Int]`, preserve order,
    dedupe, build an ordered array of row view-models.
  - Hydrate each row cache-first from `PersistedAuthor` (instant where available).
  - Lazily resolve uncached IDs via `CivitaiService.fetchUser(id:)` with bounded
    concurrency (small task pool), driven by row appearance; upsert resolved profiles
    into `PersistedAuthor`.
  - Expose per-row resolution state (placeholder vs resolved) and overall state
    (no-API-key, loading, empty, error, loaded).
- **Depends on:** `CivitaiService`, `APIKeyManager`, the SwiftData `ModelContext` for
  `PersistedAuthor` reads/upserts.
- **Interface:** published ordered `[FollowedUserRow]` + a `ViewState`; `load`, `refresh`,
  and a `resolveIfNeeded(id:)` hook called from row `onAppear`.

### `FollowingView` — new view (the tab body)

- **Does:** renders the store's state. No API key → prompt with a button into Settings;
  loading → spinner; empty → "You're not following anyone yet"; error → message + retry;
  loaded → `List` of rows (circular avatar via `CachedAsyncImage` + username). Tapping a
  row opens `UserContentView` using the platform's existing pattern (iOS
  `fullScreenCover(item:)`, macOS `feedNavigator.push(user)`). Pull-to-refresh calls
  `store.refresh()`.
- **Depends on:** `FollowingStore`, `UserContentView`, `CachedAsyncImage`, and (macOS)
  the `FeedNavigator` environment object.

### `ContentView` changes

- **iOS:** remove the Settings tab. Tabs become Images, Videos, Collections, Library,
  **Users** (`person.2` system image). 
- **macOS:** add a `.users` case to `SidebarSection` (`person.2` icon) rendering
  `FollowingView`. Settings stays in the app menu (unchanged).

### `ImageFeedView` change (iOS Settings entry point)

- **iOS:** add a gear button to the feed header `HStack` (next to `FeedFilterMenu`),
  shown on both Images and Videos, presenting `SettingsView` as a sheet.
- **macOS:** unchanged (Settings already in the app menu).

## Data flow

1. Tab appears → `FollowingStore.load()`.
2. No API key → render the sign-in prompt and stop.
3. `getFollowingUserIds()` → ordered `[Int]`; build rows in that order.
4. Each row hydrates from `PersistedAuthor` if present (immediate name/avatar).
5. Rows without a cache hit resolve lazily via `fetchUser(id:)` on `onAppear`
   (bounded concurrency); resolved profiles upsert into `PersistedAuthor`.
6. Tap a row → open `UserContentView(user:)` via the platform pattern.
7. Pull-to-refresh → `refresh()` re-runs from step 3.

## Error handling

- **No API key:** dedicated empty state with a button that opens Settings (iOS gear sheet
  / macOS app menu hint). Not treated as an error.
- **Follow-list fetch fails:** error state with a Retry button; existing rows (if any)
  remain visible.
- **Per-ID resolution fails:** that row falls back to a placeholder avatar and a best-effort
  label (cached username if any, otherwise a neutral placeholder); the rest of the list is
  unaffected. Transient failures retry on next appearance.
- **Deleted users:** hidden from the list.

## Testing

- **`FollowingStore` unit tests** against a mock `CivitaiService`: order preserved from the
  ID list; dedupe; cache-hit rows resolve without a network call; gap rows trigger exactly
  one fetch and upsert; deleted users hidden; error state on follow-list failure.
- **Decode test** for a representative `user.getById` tRPC response → `CivitaiUser`.
- **Build on both iOS and macOS targets** (this repo ships both; UI changes must compile on
  each).

## Reused unchanged

- `UserContentView` (destination, including its own Follow button for unfollowing).
- `PersistedAuthor` (profile cache).
- `CachedAsyncImage` (avatar rendering).
- `getFollowingUserIds()` / `toggleFollowUser()` (existing service methods).
- iOS `fullScreenCover(item:)` and macOS `FeedNavigator` navigation patterns.
