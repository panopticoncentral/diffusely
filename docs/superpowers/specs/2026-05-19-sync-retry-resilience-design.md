# Collection Sync Retry Resilience — Design

**Date:** 2026-05-19
**Status:** Approved (pending written-spec review)

## Context

Collection sync (`CollectionSyncService`) paginates the Civitai API one page at a
time, persisting each page and saving a resume cursor. Today every page fetch is
a plain `try`: the first transient failure (e.g. a `URLError` timeout) propagates
out of `syncImages`/`syncPosts` into `performSync`'s `catch`, which records
`lastError` and **abandons the entire run**. A single network blip kills a
multi-hundred-page backfill, and nothing automatically picks it back up — the run
just dead-ends with a "Sync error" state.

This surfaced during the date-sorting backfill (953 posts): one page timed out
and the whole refresh gave up.

## Goal

On a **transient** failure: stop gracefully (no error dead-end), show a subtle
"Sync paused — retrying…" status, auto-retry on a backoff timer **while the
collection is open**, and **resume from the saved cursor when the collection is
reopened**. **Fatal** failures keep today's behavior (stop with a real error).

Chosen approach: **retry/backoff inside the sync loop** (the page fetch is
wrapped so the loop never unwinds on a transient error). Rejected: view-level
retry orchestration (policy leaks into every screen) and an app-wide resilient
network layer (scope creep / masks errors elsewhere — YAGNI).

## Part 1 — Core mechanism

### Error classification

New pure helper (e.g. `SyncErrorClassifier`) with three outcomes:

- **Transient** (retry): `URLError` with code `.timedOut`,
  `.networkConnectionLost`, `.notConnectedToInternet`, `.cannotConnectToHost`,
  `.cannotFindHost`, `.dnsLookupFailed`, `.resourceUnavailable`.
- **Fatal** (stop with error — today's behavior): everything else, including
  `DecodingError` and any non-network error.
- **Cancellation**: `CancellationError` stays special-cased exactly as today
  (not an error, not a retry).

Known limitation, explicitly **out of scope**: `fetchImagesPage` /
`fetchPostsPage` don't inspect HTTP status, so a 429/5xx that returns a body
becomes a `DecodingError` (classified fatal). Treating HTTP status as transient
would require changing `CivitaiService` and is deferred.

### Progress model

Extend `CollectionSyncService.SyncProgress`:

```swift
struct SyncProgress {
    var itemsFetched: Int
    var isComplete: Bool
    var lastError: Error?        // fatal only — unchanged meaning
    var retryState: RetryState?  // non-nil ⇒ paused, waiting to retry
}
struct RetryState { let attempt: Int; let nextAttemptAt: Date }
```

A transient failure sets `retryState`, **never** `lastError`. `lastError`
remains exclusively a fatal-error signal.

### Retry loop

A `fetchPageWithRetry` wrapper used by both `syncImages` and `syncPosts`:

- Try the fetch for the **current cursor**.
- Success → clear `retryState`, reset attempt counter, return the page; the
  outer `while` loop proceeds normally.
- `CancellationError` → rethrow (unchanged).
- Fatal → throw → propagates to `performSync`'s `catch` → `lastError` set
  (today's behavior).
- Transient → set `retryState = RetryState(attempt: n, nextAttemptAt: now +
  delay)`, `try await Task.sleep(for: delay)` (cancellable), then loop and retry
  the **same cursor**. The sync loop never unwinds — genuine stop-and-resume.

Backoff schedule (pure function `delay(forAttempt:)`): 5s → 15s → 45s → capped
at 60s, repeating **indefinitely** while the view is open and the task isn't
cancelled. No max-attempts dead-end (matches "no action needed, seamless").

## Part 2 — "On reopen" resume correctness

Two gaps must be closed; the second is a pre-existing latent bug that directly
blocks the reopen requirement, so it is in scope.

### Stop retrying when the screen is dismissed

Today nothing cancels the sync on view dismissal — an indefinite retry loop
would run forever in the background. Add to `CollectionDetailView`:

```swift
.onDisappear { syncService?.cancelSync(for: collection.id) }
```

The cancellable `Task.sleep` and `Task.isCancelled` checks unwind the loop
promptly as a `CancellationError`. This makes it genuinely "retry **while
open**."

### Reset the persisted "is syncing" flag on any non-completion exit

`markSyncStarted` sets `collection.isSyncing = true`; only `markSyncCompleted`
clears it. If a run stops without completing (cancellation **or** fatal), the
flag stays `true` forever and `needsSync` returns `false` for a "currently
syncing" collection — so **reopen would never resume**. Fix:

- New `CollectionPersistenceService.markSyncInterrupted(for:)`: sets
  `isSyncing = false`, **keeps** `syncCursor` intact.
- `performSync` calls it on both the `CancellationError` path and the fatal
  `catch` path (in addition to setting `lastError` for fatal).
- Strengthen `needsSync` to also return `true` when `syncCursor != nil` (a pass
  is mid-flight/interrupted) **and** `collection.isSyncing == false` — so an
  interrupted pass resumes on reopen regardless of the 5-minute staleness
  window. `needsSync` cannot see the in-memory `syncTasks` (that lives in
  `CollectionSyncService`); the persisted `isSyncing` flag is the correct proxy
  because both `markSyncInterrupted` and `markSyncCompleted` now clear it, so it
  is `true` only while a sync is genuinely active.

### `isSyncing` tightened

Require a live task so the UI polling loop terminates after cancellation:

```
isSyncing(id) == syncTasks[id] != nil && !isComplete && lastError == nil
```

A non-nil `retryState` still means syncing (task alive, sleeping); a
cancelled/removed task means not syncing.

### Net flow

Leave mid-retry → task cancelled → `markSyncInterrupted` (cursor preserved) →
reopen → `.task` → `startSyncIfNeeded` → `needsSync` true (cursor present) →
`performSync` resumes from the saved cursor.

## Part 3 — UI status

`SyncProgressView` gets one new branch, ordered **before** the generic spinner
branch (a non-nil `retryState` always implies `!isComplete && lastError == nil`):

- Icon: a quiet SF Symbol (e.g. `clock.arrow.circlepath`) in `.secondary` — not
  the orange warning used for fatal errors.
- Text: `"Sync paused — retrying…"`, `.caption`, `.secondary`.
- No countdown timer, no button (matches "subtle status, no action needed"). A
  live countdown would need a recurring timer to re-render — out of scope.

Existing "Syncing… N items", "Synced N items", and orange "Sync error" branches
are unchanged. Because `isSyncing` stays `true` during retries, the collection's
polling loop keeps calling `reloadContent()`; already-fetched items stay visible
and the list updates when a retry succeeds.

## Testing

**Unit (`DiffuselyTests` target):**
- `SyncErrorClassifier`: each transient `URLError` code → transient;
  `DecodingError` and generic errors → fatal; `CancellationError` → neither.
- Backoff: `delay(forAttempt:)` returns 5s, 15s, 45s, then 60s cap;
  deterministic, no sleeping in tests.

**Manual integration:**
- Start a large sync; enable Airplane Mode mid-run → "Sync paused — retrying…"
  appears, `lastError` stays nil. Disable Airplane Mode → next backoff tick
  recovers and progresses.
- Leave the screen while paused → retries stop.
- Reopen → resumes from the saved cursor.
- Trigger a fatal error (e.g. invalid auth) → orange "Sync error" as today (no
  infinite retry).

## Affected files

- `Diffusely/Services/CollectionSyncService.swift` — `SyncProgress`/`RetryState`,
  `fetchPageWithRetry`, classifier usage, `isSyncing`, interrupt handling.
- `Diffusely/Services/CollectionPersistenceService.swift` —
  `markSyncInterrupted(for:)`, strengthened `needsSync`.
- `Diffusely/Views/CollectionDetailView.swift` — `.onDisappear` cancel.
- `Diffusely/Views/SyncProgressView.swift` — paused/retrying branch.
- New: `SyncErrorClassifier` + backoff (pure, unit-tested) — likely in
  `CollectionSyncService.swift` or a small adjacent file.
- New: `DiffuselyTests` cases for classifier + backoff.

## Out of scope

- HTTP-status-aware transient classification (429/5xx) — needs `CivitaiService`
  changes.
- Live retry countdown UI.
- Retry/backoff for non-collection-sync network calls (feed, detail).
- Max-attempts limit / manual "Retry now" button.
