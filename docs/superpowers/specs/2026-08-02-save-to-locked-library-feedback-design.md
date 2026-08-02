# Save-to-Locked-Library Feedback & Unlock — Design

**Date:** 2026-08-02
**Status:** Approved, ready for implementation planning

## Summary

When a user taps **Save to Library** while the Library's at-rest encryption vault is
**locked**, the save is correctly refused before any download or disk write — but today
that refusal is **completely silent**: no message, no prompt, the button just reverts.
This feature surfaces that failure and offers a one-tap path to unlock: an app-level
alert appears, its **Unlock** button presents the existing `LibraryUnlockView` in a
sheet, and on a successful unlock the save the user attempted **re-fires automatically**.

The same alert mechanism also fixes a broader gap: *all* save failures
(`downloadFailed`, `writeFailed`, `alreadySaved`) are silently swallowed today. Binding
one app-level alert to `LibrarySaveService.lastError` gives every save failure a visible
message for ~no extra work.

## Motivation

The "Save to Library" button lives in four browse views — `ImageFeedItemView`,
`ImageDetailView`, `PostDetailView`, `AuthorContentGrid` — all firing through the
`LibrarySaveService.shared` singleton. The browse experience is **never gated** behind
an unlock (only the Library tab is), so a user browsing feeds with a configured-but-locked
vault can and will tap Save.

When they do, `LibrarySaveService.performSave` throws
`LibraryBackfillSidecarStoreError.vaultLocked` (the deliberate fail-closed guard that
prevents writing plaintext into an encrypted-but-locked container). The error is caught,
mapped to `.writeFailed`, stored in the `@Published var lastError` — and **never rendered
anywhere**. The user sees the button flash "Saving to Library…" then revert to "Save to
Library" with no explanation and no saved item.

## Scope decisions

- **Unlock UX:** in-place **sheet + auto-retry**. The unlock happens right where the user
  is (not by switching to the Library tab), and the pending save re-fires on success, so
  the user's original intent ("save this image") is fulfilled with no manual re-tap.
  (Decision.)
- **Error scope:** surface **all** save errors through the shared alert, not only the
  locked case. Locked → Unlock offer; everything else → message + OK. (Decision.)
- **Out of scope:** no changes to the encryption backend, the `LibraryVaultProvider`
  gate, or the Library tab. No tab-switching navigation. The four browse views need **no
  changes** — they already observe the singleton.

## Data flow

```
User taps Save (any of 4 browse views)
  └─ LibrarySaveService.save()  →  performSave()  ──throws──> vaultLocked
        └─ save()'s catch → recordFailure(vaultLocked, image, postTitle, publishedAt)
              ├─ append PendingLockedSave
              └─ lastError = .libraryLocked
  App-level alert (SaveFeedbackModifier, hosted on ContentView) appears
     ├─ "Not Now" → discardPendingLockedSaves(); lastError cleared
     └─ "Unlock"  → present SaveUnlockSheet (LibraryUnlockView)
           ├─ user unlocks (password / Face ID / recovery key)
           │     └─ provider.state flips off .locked
           │           └─ onUnlocked → retryPendingLockedSaves()  → save() re-fires
           └─ Cancel / swipe-dismiss → discardPendingLockedSaves()
```

## Components

### 1. `LibrarySaveError` (edit — `LibrarySaveService.swift`)

Add a dedicated case so the UI can distinguish "locked" from a generic write failure:

- `case libraryLocked`, with `errorDescription` = "Your Library is locked. Unlock it to
  save."
- `var isLibraryLocked: Bool` — pattern-match helper so the alert needs no `Equatable`
  conformance (`LibrarySaveError` has a `writeFailed(Error)` associated value and is not
  `Equatable`; nothing compares it with `==`).
- `var alertTitle: String` — per-case title: `.libraryLocked` → "Library Locked",
  `.alreadySaved` → "Already Saved", `.downloadFailed` → "Download Failed",
  `.writeFailed` → "Couldn't Save".

### 2. `LibrarySaveService` (edit)

- **`struct PendingLockedSave`** — captures what a retry needs: `image: CivitaiImage`,
  `knownPostTitle: String?`, `knownPublishedAt: Date?` (exactly the `save()` parameters).
- **`private(set) var pendingLockedSaves: [PendingLockedSave]`** — held in its **own
  property, independent of `lastError`**. This is the key correctness point: because
  pending retries are not stored inside `lastError`, the alert's `isPresented` binding can
  freely clear `lastError` on any dismissal without ever losing a pending retry, avoiding
  the SwiftUI button-action-vs-binding-setter ordering race.
- **`func recordFailure(_ error: Error, image:knownPostTitle:knownPublishedAt:)`**
  (internal, for testability — mirrors why `performSave` is already `internal`). Replaces
  the inline catch body:
  - `LibraryBackfillSidecarStoreError.vaultLocked` → append `PendingLockedSave` (dedup by
    `itemID` to bound growth) + `lastError = .libraryLocked`.
  - other `LibrarySaveError` → `lastError = error` as-is.
  - anything else → `lastError = .writeFailed(error)`.
- **`save()` catch** calls `recordFailure(...)` (it has `image`, `knownPostTitle`,
  `knownPublishedAt` in scope).
- **`func retryPendingLockedSaves()`** — snapshot `pendingLockedSaves`, clear it, nil
  `lastError`, then re-`save()` each entry. The existing `guard !inFlight.contains` in
  `save()` naturally dedupes concurrent duplicates.
- **`func discardPendingLockedSaves()`** — `pendingLockedSaves.removeAll()` (used by
  Not-Now / sheet-cancel / sheet-dismiss).
- **`func clearError()`** — nils `lastError` only, leaving pending intact (used by the
  alert's `isPresented` setter).

### 3. `SaveFeedbackModifier` + `SaveUnlockSheet` (new file — `Views/SaveFeedbackModifier.swift`)

A `ViewModifier` observing `LibrarySaveService.shared` and `LibraryVaultProvider.shared`,
with one `@State private var showUnlockSheet`:

- **`.alert`** driven by `lastError` (title = `alertTitle`, message = `errorDescription`):
  - `isLibraryLocked` → **Unlock** (sets `showUnlockSheet = true`) + **Not Now**
    (`role: .cancel`, calls `discardPendingLockedSaves()`).
  - otherwise → **OK** (`role: .cancel`).
  - `isPresented` binding: `get { lastError != nil }`, `set { if !$0 { clearError() } }`
    — clears only the error on dismissal; pending survives for the Unlock path.
- **`.sheet(isPresented: $showUnlockSheet, onDismiss: { discardPendingLockedSaves() })`**
  hosting `SaveUnlockSheet`. `onDismiss` runs `discardPendingLockedSaves()` as an
  idempotent safety net: after a successful unlock, `retryPendingLockedSaves()` has
  already emptied the list (so it's a no-op); after a swipe-to-dismiss it performs the
  cleanup.
- **`SaveUnlockSheet`** — a `NavigationStack` wrapping the existing, unmodified
  `LibraryUnlockView(provider:)`, plus a Cancel toolbar button. It watches
  `provider.state` via `.onChange`; when the state flips off `.locked` it calls
  `onUnlocked`, which runs `retryPendingLockedSaves()` **before** closing the sheet.
  `LibraryUnlockView`'s existing `.task { await biometrics() }` means Face ID is offered
  immediately on present — no new unlock code.
- Expose a `View.saveFeedback()` convenience extension.

### 4. `ContentView` (edit)

Apply `.saveFeedback()` once per platform branch (mirroring the existing per-branch
`.task { await startLibrarySubsystem() }`). One host at the root covers all four save call
sites because they are all descendants; the alert/sheet present over whichever
tab/section is active.

### 5. Tests (extend `LibrarySaveServiceTests.swift`)

Network-free and deterministic, like the existing suite:

- `recordFailure(vaultLocked, …)` sets `lastError == .libraryLocked` (via `isLibraryLocked`)
  and appends exactly one `PendingLockedSave` carrying the image + post title + date.
- `recordFailure` of a non-locked `LibrarySaveError` maps it through unchanged and leaves
  `pendingLockedSaves` empty; a non-`LibrarySaveError` maps to `.writeFailed`.
- Duplicate `recordFailure(vaultLocked)` for the same `itemID` does not grow pending past
  one entry (dedup).
- `discardPendingLockedSaves()` empties pending; `clearError()` nils `lastError` while
  leaving pending intact.
- `retryPendingLockedSaves()` clears pending (its re-`save()` fan-out is fire-and-forget;
  the test asserts the list is drained, not the network result).

## Testing / verification

- New + existing unit tests pass (`LibrarySaveServiceTests`).
- Builds on **both** iOS and macOS targets (this repo ships both; UI modifier and sheet
  must compile under each `#if os(...)` branch).
- Manual smoke: with a configured, locked vault, tapping Save in a feed shows the
  "Library Locked" alert; **Unlock** presents the unlock sheet; a successful unlock
  dismisses it and the image lands in the Library; **Not Now** / swipe-dismiss leaves
  nothing saved and no lingering pending state.
