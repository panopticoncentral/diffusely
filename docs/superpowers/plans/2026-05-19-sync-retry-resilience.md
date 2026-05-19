# Collection Sync Retry Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make collection sync survive transient network failures by retrying the failing page with backoff while the collection is open, and resuming from the saved cursor on reopen, instead of dead-ending the whole run.

**Architecture:** A pure error-classifier + backoff function decides transient vs fatal. A `fetchPageWithRetry` wrapper inside the sync loop retries the *same cursor* on transient errors (the loop never unwinds), surfacing a `retryState` on `SyncProgress`. Fatal errors keep today's behavior. Persisted `isSyncing` is reset on any non-completion exit so reopen resumes from the cursor.

**Tech Stack:** Swift, SwiftUI, SwiftData, Swift Testing (`import Testing`, `@Test`, `#expect`). Spec: `docs/superpowers/specs/2026-05-19-sync-retry-resilience-design.md`.

---

## File Structure

- **Create** `Diffusely/Services/SyncRetryPolicy.swift` — pure, testable: `SyncErrorClassification` enum, `classifySyncError(_:)`, `syncRetryDelay(forAttempt:)`. No dependencies on services.
- **Create** `DiffuselyTests/SyncRetryPolicyTests.swift` — unit tests for the above.
- **Modify** `Diffusely/Services/CollectionSyncService.swift` — `RetryState` type, extend `SyncProgress`, `fetchPageWithRetry`, wire into `syncImages`/`syncPosts`, tighten `isSyncing`, interrupt handling in `performSync`.
- **Modify** `Diffusely/Services/CollectionPersistenceService.swift` — add `markSyncInterrupted(for:)`, strengthen `needsSync`.
- **Modify** `Diffusely/Views/CollectionDetailView.swift` — `.onDisappear` cancels the sync.
- **Modify** `Diffusely/Views/SyncProgressView.swift` — paused/retrying branch.

Standard build/test commands (pick an installed simulator via `xcrun simctl list devices available`; examples use `iPhone 17 Pro`):

- Build: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
- Test: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/SyncRetryPolicyTests 2>&1 | tail -20`

---

## Task 1: SyncRetryPolicy (pure classifier + backoff) — TDD

**Files:**
- Create: `Diffusely/Services/SyncRetryPolicy.swift`
- Test: `DiffuselyTests/SyncRetryPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/SyncRetryPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

struct SyncRetryPolicyTests {

    @Test func transientURLErrorsClassifyAsTransient() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .resourceUnavailable
        ]
        for code in codes {
            #expect(classifySyncError(URLError(code)) == .transient)
        }
    }

    @Test func decodingErrorClassifiesAsFatal() {
        let err = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        #expect(classifySyncError(err) == .fatal)
    }

    @Test func genericErrorClassifiesAsFatal() {
        let err = NSError(domain: "x", code: 1)
        #expect(classifySyncError(err) == .fatal)
    }

    @Test func badServerResponseURLErrorIsFatal() {
        #expect(classifySyncError(URLError(.badServerResponse)) == .fatal)
    }

    @Test func cancellationClassifiesAsCancellation() {
        #expect(classifySyncError(CancellationError()) == .cancellation)
    }

    @Test func backoffScheduleMatchesSpec() {
        #expect(syncRetryDelay(forAttempt: 1) == 5)
        #expect(syncRetryDelay(forAttempt: 2) == 15)
        #expect(syncRetryDelay(forAttempt: 3) == 45)
        #expect(syncRetryDelay(forAttempt: 4) == 60)
        #expect(syncRetryDelay(forAttempt: 10) == 60)
        #expect(syncRetryDelay(forAttempt: 0) == 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/SyncRetryPolicyTests 2>&1 | tail -20`
Expected: FAIL — build error, `classifySyncError`/`syncRetryDelay` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Diffusely/Services/SyncRetryPolicy.swift`:

```swift
import Foundation

/// Outcome of inspecting a sync error.
enum SyncErrorClassification: Equatable {
    case transient    // retry with backoff
    case fatal        // stop the run, surface as lastError
    case cancellation // task was cancelled — not an error
}

/// Classifies an error thrown by a collection page fetch.
///
/// Known limitation: `fetchImagesPage`/`fetchPostsPage` don't inspect HTTP
/// status, so a 429/5xx that returns a body surfaces as a `DecodingError`
/// and is classified `.fatal`. HTTP-status-aware classification is out of
/// scope (see spec).
func classifySyncError(_ error: Error) -> SyncErrorClassification {
    if error is CancellationError { return .cancellation }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return .transient
        default:
            return .fatal
        }
    }
    return .fatal
}

/// Backoff delay in seconds for a 1-based retry attempt.
/// Schedule: 5s, 15s, 45s, then capped at 60s indefinitely.
func syncRetryDelay(forAttempt attempt: Int) -> Double {
    switch attempt {
    case ..<2:  return 5   // attempt 0 (defensive) and 1
    case 2:     return 15
    case 3:     return 45
    default:    return 60
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/SyncRetryPolicyTests 2>&1 | tail -20`
Expected: PASS — all `SyncRetryPolicyTests` pass (TEST SUCCEEDED).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/SyncRetryPolicy.swift DiffuselyTests/SyncRetryPolicyTests.swift
git commit -m "Add pure sync error classifier and backoff schedule

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Extend SyncProgress with retryState

**Files:**
- Modify: `Diffusely/Services/CollectionSyncService.swift:7-11` (the `SyncProgress` struct)

- [ ] **Step 1: Add RetryState and the retryState field**

Replace this exact block:

```swift
    struct SyncProgress {
        var itemsFetched: Int
        var isComplete: Bool
        var lastError: Error?
    }
```

with:

```swift
    struct SyncProgress {
        var itemsFetched: Int
        var isComplete: Bool
        var lastError: Error?        // fatal only — unchanged meaning
        var retryState: RetryState?  // non-nil ⇒ paused, waiting to retry
    }

    struct RetryState {
        let attempt: Int
        let nextAttemptAt: Date
    }
```

- [ ] **Step 2: Update the one place SyncProgress is constructed**

In `performSync`, the initializer currently reads:

```swift
        syncProgress[collection.id] = SyncProgress(
            itemsFetched: initialCount,
            isComplete: false,
            lastError: nil
        )
```

Replace with:

```swift
        syncProgress[collection.id] = SyncProgress(
            itemsFetched: initialCount,
            isComplete: false,
            lastError: nil,
            retryState: nil
        )
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Services/CollectionSyncService.swift
git commit -m "Add retryState to SyncProgress

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Persistence — markSyncInterrupted + strengthen needsSync

**Files:**
- Modify: `Diffusely/Services/CollectionPersistenceService.swift` (`needsSync` at line 364; add new method near `markSyncCompleted` at line 330)

- [ ] **Step 1: Add markSyncInterrupted**

Immediately AFTER the closing brace of `markSyncCompleted(for:)` (the method starting at line 330), insert:

```swift

    /// Stops the persisted "is syncing" flag without clearing the resume
    /// cursor, so an interrupted pass resumes from the last good page.
    func markSyncInterrupted(for collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        collection.isSyncing = false
        // Intentionally keep collection.syncCursor for resume.
        try? modelContext.save()
    }
```

- [ ] **Step 2: Strengthen needsSync**

Replace this exact block inside `needsSync`:

```swift
        // If currently syncing, don't start another
        if collection.isSyncing {
            return false
        }

        // If never completed a sync, need to sync
        guard let lastSync = collection.lastSyncCompleted else {
            return true
        }
```

with:

```swift
        // If currently syncing, don't start another
        if collection.isSyncing {
            return false
        }

        // An interrupted pass left a resume cursor — resume it regardless of
        // staleness. (isSyncing is false here, and markSyncInterrupted/
        // markSyncCompleted both reset it, so this only fires for a genuinely
        // interrupted pass.)
        if collection.syncCursor != nil {
            return true
        }

        // If never completed a sync, need to sync
        guard let lastSync = collection.lastSyncCompleted else {
            return true
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Services/CollectionPersistenceService.swift
git commit -m "Add markSyncInterrupted and resume interrupted pass in needsSync

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Retry loop wiring in CollectionSyncService

**Files:**
- Modify: `Diffusely/Services/CollectionSyncService.swift` — `isSyncing` (line 37), `performSync` catch (lines 73-77), `syncImages` fetch call, `syncPosts` fetch call; add `fetchPageWithRetry`.

- [ ] **Step 1: Tighten isSyncing**

Replace this exact block:

```swift
    func isSyncing(collectionId: Int) -> Bool {
        guard let progress = syncProgress[collectionId] else { return false }
        return !progress.isComplete && progress.lastError == nil
    }
```

with:

```swift
    func isSyncing(collectionId: Int) -> Bool {
        // Require a live task so the UI polling loop terminates after a
        // cancellation removes the task. A non-nil retryState still counts
        // as syncing (the task is alive, just sleeping between retries).
        guard syncTasks[collectionId] != nil,
              let progress = syncProgress[collectionId] else { return false }
        return !progress.isComplete && progress.lastError == nil
    }
```

- [ ] **Step 2: Add fetchPageWithRetry**

Immediately BEFORE the line `func cancelSync(for collectionId: Int) {` (line 172), insert:

```swift
    /// Runs `fetch`, retrying the same call on transient errors with backoff.
    /// Sets `retryState` while paused; clears it on success. Fatal errors and
    /// cancellation propagate (the sync loop / performSync handle them).
    private func fetchPageWithRetry<T>(
        collectionId: Int,
        _ fetch: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                let result = try await fetch()
                if syncProgress[collectionId]?.retryState != nil {
                    syncProgress[collectionId]?.retryState = nil
                }
                return result
            } catch {
                try Task.checkCancellation()
                switch classifySyncError(error) {
                case .cancellation:
                    throw error
                case .fatal:
                    throw error
                case .transient:
                    attempt += 1
                    let delay = syncRetryDelay(forAttempt: attempt)
                    syncProgress[collectionId]?.retryState = RetryState(
                        attempt: attempt,
                        nextAttemptAt: Date().addingTimeInterval(delay)
                    )
                    try await Task.sleep(for: .seconds(delay))
                    // loop: retry the same fetch (same cursor)
                }
            }
        }
    }
```

- [ ] **Step 3: Route the image fetch through the retry wrapper**

In `syncImages`, replace this exact block:

```swift
            let (images, nextCursor) = try await civitaiService.fetchImagesPage(
                collectionId: collection.id,
                cursor: cursor,
                limit: 100
            )
```

with:

```swift
            let (images, nextCursor) = try await fetchPageWithRetry(collectionId: collection.id) {
                try await self.civitaiService.fetchImagesPage(
                    collectionId: collection.id,
                    cursor: cursor,
                    limit: 100
                )
            }
```

- [ ] **Step 4: Route the post fetch through the retry wrapper**

In `syncPosts`, replace this exact block:

```swift
            let (posts, nextCursor) = try await civitaiService.fetchPostsPage(
                collectionId: collection.id,
                cursor: cursor,
                limit: 100
            )
```

with:

```swift
            let (posts, nextCursor) = try await fetchPageWithRetry(collectionId: collection.id) {
                try await self.civitaiService.fetchPostsPage(
                    collectionId: collection.id,
                    cursor: cursor,
                    limit: 100
                )
            }
```

- [ ] **Step 5: Reset persisted isSyncing on any non-completion exit**

In `performSync`, replace this exact block:

```swift
        } catch {
            if !(error is CancellationError) {
                syncProgress[collection.id]?.lastError = error
            }
        }
```

with:

```swift
        } catch {
            if !(error is CancellationError) {
                syncProgress[collection.id]?.lastError = error
            }
            // Reset the persisted "is syncing" flag (cursor preserved) so
            // needsSync allows a resume on reopen.
            persistenceService.markSyncInterrupted(for: collection.id)
        }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Services/CollectionSyncService.swift
git commit -m "Retry transient page failures with backoff; reset isSyncing on interrupt

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Cancel sync when the collection view is dismissed

**Files:**
- Modify: `Diffusely/Views/CollectionDetailView.swift` (add `.onDisappear` next to the existing `.onChange(of: selectedSort)`)

- [ ] **Step 1: Add .onDisappear**

Find this exact block (it follows `.onReceive(...)` and precedes the closing of the ScrollView modifiers):

```swift
            .onChange(of: selectedSort) {
                Task { await reloadContent() }
            }
```

Replace with:

```swift
            .onChange(of: selectedSort) {
                Task { await reloadContent() }
            }
            .onDisappear {
                // Stop the retry/backoff loop when leaving the screen; the
                // saved cursor lets it resume on reopen.
                syncService?.cancelSync(for: collection.id)
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/CollectionDetailView.swift
git commit -m "Cancel collection sync on view disappear

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: SyncProgressView paused/retrying status

**Files:**
- Modify: `Diffusely/Views/SyncProgressView.swift:6-36` (the `body`)

- [ ] **Step 1: Add the retry branch to icon and text**

Replace this exact block:

```swift
        HStack(spacing: 8) {
            if !progress.isComplete && progress.lastError == nil {
                ProgressView()
                    .scaleEffect(0.8)
            } else if progress.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            } else if progress.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
            }

            if let error = progress.lastError {
                Text("Sync error")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if progress.isComplete {
                Text("Synced \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Syncing... \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
```

with:

```swift
        HStack(spacing: 8) {
            if progress.retryState != nil {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
            } else if !progress.isComplete && progress.lastError == nil {
                ProgressView()
                    .scaleEffect(0.8)
            } else if progress.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            } else if progress.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
            }

            if progress.retryState != nil {
                Text("Sync paused — retrying…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if progress.lastError != nil {
                Text("Sync error")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if progress.isComplete {
                Text("Synced \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Syncing... \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
```

Note: the `else if let error = progress.lastError` was changed to `else if progress.lastError != nil` because the bound `error` was unused; behavior is identical.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|warning: .*error.*never used|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/SyncProgressView.swift
git commit -m "Show subtle paused/retrying status during sync backoff

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full build + manual integration verification

**Files:** none (verification only)

- [ ] **Step 1: Full clean build + full unit test run**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Then: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/SyncRetryPolicyTests 2>&1 | tail -20`
Expected: BUILD SUCCEEDED; SyncRetryPolicyTests all pass.

- [ ] **Step 2: Manual integration checklist (real device or simulator with a large collection)**

The sync loop depends on the concrete `CivitaiService` networking and cannot be unit-tested without a service-injection refactor (out of scope). Verify manually and record results:

1. Open a large collection so a sync starts ("Syncing… N items"). Enable Airplane Mode mid-sync → status changes to "Sync paused — retrying…" with the clock icon; `lastError` stays nil (no orange "Sync error"). Items already fetched remain visible.
2. Disable Airplane Mode → within one backoff interval (≤60s) the status returns to "Syncing… N items" and the count increases. Resumes from where it left off (no duplicate restart from page 1 — watch the `[Sync] Fetching page` logs: the cursor is unchanged across the retry).
3. While "Sync paused — retrying…", navigate back out of the collection, then reopen it → sync resumes (status shows syncing again; `[Sync] Starting … cursor:` log shows a non-nil resume cursor, not `nil`).
4. Trigger a fatal error (e.g. sign out / invalid API key so the response fails to decode) → orange "Sync error" appears and it does NOT loop "retrying…" forever.
5. Let a sync complete fully with good network → "Synced N items" with green check, as before (no regression).

- [ ] **Step 3: Commit verification notes (optional)**

If you keep a verification log, add it; otherwise no commit. No code changes in this task.

---

## Self-Review

**Spec coverage:**
- Error classification (transient/fatal/cancellation) → Task 1. ✔
- Backoff 5/15/45/60 indefinite → Task 1 (`syncRetryDelay`) + Task 4 (`fetchPageWithRetry` loop). ✔
- `SyncProgress.retryState` / `RetryState` → Task 2. ✔
- Retry same cursor, loop never unwinds, clear on success → Task 4 Steps 2–4. ✔
- Fatal still sets `lastError` (today's behavior) → Task 4 Step 2 (`.fatal: throw`) + existing `performSync` catch. ✔
- `markSyncInterrupted` + strengthened `needsSync` → Task 3. ✔
- `performSync` resets persisted isSyncing on cancellation AND fatal → Task 4 Step 5. ✔
- `isSyncing` requires live task → Task 4 Step 1. ✔
- `.onDisappear` cancels sync → Task 5. ✔
- Subtle paused UI, no countdown/button, ordered before spinner → Task 6. ✔
- Unit tests for classifier + backoff; manual integration → Task 1 + Task 7. ✔

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✔

**Type consistency:** `SyncErrorClassification` (`.transient`/`.fatal`/`.cancellation`), `classifySyncError(_:)`, `syncRetryDelay(forAttempt:)`, `RetryState(attempt:nextAttemptAt:)`, `SyncProgress.retryState`, `markSyncInterrupted(for:)`, `fetchPageWithRetry(collectionId:_:)`, `cancelSync(for:)` are used identically across Tasks 1–6. ✔

**Note on Task ordering:** Task 3 (adds `markSyncInterrupted`) precedes Task 4 (which calls it). Task 2 (adds `retryState`) precedes Tasks 4 and 6 (which use it). Correct.
