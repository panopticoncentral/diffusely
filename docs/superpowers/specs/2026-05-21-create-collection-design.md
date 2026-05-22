# Create a New Collection from the Collections List — Design

**Date:** 2026-05-21
**Status:** Approved

## Goal

Let users create a new photo/video ("Image") or post ("Post") collection directly
from the collections list, instead of having to create it on the Civitai website.

## Background

`CollectionsView` currently shows a cache-first grid of the user's Image and Post
collections with a Refresh action. There is no way to create a collection in-app.

The Civitai API supports creation via the `collection.upsert` tRPC procedure
(`POST /api/trpc/collection.upsert?batch=1`, authenticated). Verified against the
Civitai source (`src/server/schema/collection.schema.ts`,
`src/server/services/collection.service.ts`):

- `name` — required, non-empty, max 30 chars.
- `type` — `CollectionType` enum; we use `"Image"` or `"Post"`.
- `description` — optional, max 300 chars.
- `read` — `CollectionReadConfiguration`: `Private` | `Public` | `Unlisted`
  (DB default `Private`).
- `write` — `CollectionWriteConfiguration`, DB default `Private`. Not exposed; left
  at the server default.

When `id` is omitted, `upsert` creates a new collection. All `collectionItem`
fields it merges are optional, so a minimal create payload is `{ name, type }`.

## Entry Point (Mac + iOS)

A single **"+" button** in the navigation toolbar's primary-action area, alongside
the existing Refresh button. This is the standard "new item" idiom on both iOS and
macOS. Tapping it presents `CreateCollectionView` as a sheet. No pre-select type
menu — the form itself has a type picker.

The "+" button is only shown when `apiKeyManager.hasAPIKey` is true (consistent
with the existing Refresh button).

## New View: `CreateCollectionView`

A `Form` inside a `NavigationStack`, styled like `SettingsView` /
`CollectionPickerView`, with the macOS `.frame(minWidth:…)` sizing those views use.

Fields:

- **Type** — segmented `Picker`: **Photo / Video** (→ API type `"Image"`) and
  **Post** (→ `"Post"`). Defaults to Photo / Video.
- **Name** — `TextField`, required. Input capped at 30 chars.
- **Description** — optional multi-line `TextField` (`axis: .vertical`). Input
  capped at 300 chars.
- **Privacy** — `Picker` mapping to the API `read` config: **Private** (default),
  **Public**, **Unlisted**.

Toolbar:

- **Cancel** — `.cancellationAction`, dismisses without creating.
- **Create** — `.confirmationAction`. Disabled when the trimmed name is empty or a
  save is in flight. Shows a `ProgressView` during the request.

Errors surface in an `.alert`; the form stays open so the user can retry.

The view takes an `onCreated: (Int) -> Void` (or `onCreated: () -> Void`) callback
that the parent uses to trigger a list refresh after dismissal.

## Service Layer: `CivitaiService.createCollection`

New method following the existing `addImageToCollection` pattern:

```swift
func createCollection(
    name: String,
    type: String,            // "Image" | "Post"
    description: String?,
    read: String             // "Private" | "Public" | "Unlisted"
) async throws -> Int
```

- `POST {baseURL}/collection.upsert?batch=1`, `Content-Type: application/json`,
  `Authorization: Bearer <apiKey>` (throws `URLError(.userAuthenticationRequired)`
  if no key, like the other write methods).
- Body shape: `{"0":{"json":{ name, type, description?, read }}}`.
- On a 2xx response, parse the new collection `id` out of the tRPC response and
  return it. Non-2xx throws `URLError(.badServerResponse)`.

To keep the payload testable, the JSON body construction is factored into a small
pure helper:

```swift
static func makeUpsertBody(
    name: String, type: String, description: String?, read: String
) -> [String: Any]
```

`createCollection` calls `makeUpsertBody` and serializes its result. Omit
`description` from the payload when nil/empty.

## Flow After Creation

On success, the sheet dismisses and `CollectionsView` calls the existing
`forceListRefresh()`, which pulls the new (empty) collection into the grid. No new
caching or persistence code is required — the existing list-sync path handles it.

## Testing

A lightweight unit test in the existing `DiffuselyTests` target asserting
`makeUpsertBody` produces the correct `name` / `type` / `description` / `read` JSON:

- Both collection types (`"Image"`, `"Post"`).
- Each privacy value (`Private`, `Public`, `Unlisted`).
- Description present vs. nil/empty (omitted).

Network round-trips remain manual, consistent with the other write methods
(`addImageToCollection`, etc.), which are not unit-tested.

## Files Touched

- **New:** `Diffusely/Views/CreateCollectionView.swift`
- **Edit:** `Diffusely/Services/CivitaiService.swift` — add `createCollection` and
  `makeUpsertBody`.
- **Edit:** `Diffusely/Views/CollectionsView.swift` — toolbar "+" button + sheet
  presentation state + refresh-on-create.
- **New test:** `DiffuselyTests/CreateCollectionTests.swift`.
- **Edit:** `Diffusely.xcodeproj/project.pbxproj` — register the two new files.

## Non-Goals

- Editing or deleting existing collections.
- Setting a cover image at creation time (the API does not yet support cover image
  on create).
- Exposing the `write` (contributor) configuration.
- Creating Model or Article collections.
