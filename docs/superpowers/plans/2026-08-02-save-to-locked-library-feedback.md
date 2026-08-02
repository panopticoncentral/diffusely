# Save-to-Locked-Library Feedback & Unlock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface every "Save to Library" failure as an alert, and when the failure is a locked encryption vault, offer a one-tap unlock (in-place sheet) that auto-retries the save on success.

**Architecture:** The four browse views already fire saves through the `LibrarySaveService.shared` singleton and set a `@Published lastError` that nothing renders. Add a `.libraryLocked` error case + a separate `pendingLockedSaves` retry queue on the service, then bind a single app-level `ViewModifier` (attached at the ContentView root) to `lastError` for the alert, hosting the existing `LibraryUnlockView` in a sheet for the unlock path. The four browse views are not touched.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`import Testing`), Xcode project `Diffusely.xcodeproj` (scheme `Diffusely`).

## Global Constraints

- Must build on **both** the iOS and macOS targets (single scheme `Diffusely`, `#if os(...)` where platform APIs differ).
- Unit tests must be **network-free and deterministic** (follow the existing `LibrarySaveServiceTests` pattern: inject `resolveVaultContext`, never hit `LibraryVaultProvider.shared`).
- **No changes** to: the encryption backend, `LibraryVaultProvider` gate logic, the Library tab, or the four browse views (`ImageFeedItemView`, `ImageDetailView`, `PostDetailView`, `AuthorContentGrid`).
- Pending retries live in their **own** service property, independent of `lastError`, so the alert binding can clear `lastError` on any dismissal without dropping a queued retry.
- User-facing copy (verbatim):
  - `.libraryLocked` message: `Your Library is locked. Unlock it to save.`
  - Alert titles: `Library Locked`, `Already Saved`, `Download Failed`, `Couldn't Save`.
  - Buttons: `Unlock`, `Not Now`, `OK`, `Cancel`. Sheet title: `Unlock Library`.
- `LibrarySaveError` is **not** `Equatable` (its `.writeFailed(Error)` associated value blocks synthesis) and nothing compares it with `==`. Do not add `Equatable`; use the `isLibraryLocked` helper and `switch`. (`someOptional == nil` still compiles without `Equatable`.)

## File Structure

- **Modify** `Diffusely/Services/Library/LibrarySaveService.swift` — add the `.libraryLocked` case + helpers (Task 1); add the `PendingLockedSave` queue, `recordFailure`, `retryPendingLockedSaves`, `discardPendingLockedSaves`, `clearError`, and rewire `save()`'s catch (Task 2).
- **Create** `Diffusely/Views/SaveFeedbackModifier.swift` — the `SaveFeedbackModifier` `ViewModifier`, the private `SaveUnlockSheet`, and the `View.saveFeedback()` extension (Task 3).
- **Modify** `Diffusely/ContentView.swift` — apply `.saveFeedback()` at the root of each platform branch (Task 4).
- **Modify** `DiffuselyTests/LibrarySaveServiceTests.swift` — unit tests for Tasks 1 & 2.

---

### Task 1: `LibrarySaveError.libraryLocked` case + UI helpers

**Files:**
- Modify: `Diffusely/Services/Library/LibrarySaveService.swift:5-17`
- Test: `DiffuselyTests/LibrarySaveServiceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `LibrarySaveError.libraryLocked` (new case, no associated value).
  - `var LibrarySaveError.isLibraryLocked: Bool`
  - `var LibrarySaveError.alertTitle: String`
  - `LibrarySaveError.errorDescription` now also handles `.libraryLocked`.

- [ ] **Step 1: Write the failing test**

Add to `DiffuselyTests/LibrarySaveServiceTests.swift`, inside the `LibrarySaveServiceTests` suite:

```swift
// MARK: - LibrarySaveError helpers

@Test func libraryLockedErrorExposesHelpers() {
    let locked = LibrarySaveError.libraryLocked
    #expect(locked.isLibraryLocked)
    #expect(locked.alertTitle == "Library Locked")
    #expect(locked.errorDescription == "Your Library is locked. Unlock it to save.")
}

@Test func nonLockedErrorsAreNotLockedAndHaveTitles() {
    #expect(!LibrarySaveError.alreadySaved.isLibraryLocked)
    #expect(LibrarySaveError.alreadySaved.alertTitle == "Already Saved")
    #expect(LibrarySaveError.downloadFailed.alertTitle == "Download Failed")
    #expect(LibrarySaveError.writeFailed(LibrarySaveError.downloadFailed).alertTitle == "Couldn't Save")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySaveServiceTests test
```
Expected: FAIL — compile error, `libraryLocked`/`isLibraryLocked`/`alertTitle` do not exist yet. (If `iPhone 16` is not installed, substitute any booted-capable simulator from `xcrun simctl list devices available`.)

- [ ] **Step 3: Add the case and helpers**

Replace the whole `enum LibrarySaveError` (lines 5-17) with:

```swift
enum LibrarySaveError: LocalizedError {
    case alreadySaved
    case downloadFailed
    case writeFailed(Error)
    case libraryLocked

    var errorDescription: String? {
        switch self {
        case .alreadySaved: return "Already in your library."
        case .downloadFailed: return "Couldn't download the original media. Check your connection and try again."
        case .writeFailed(let error): return "Couldn't save to your library: \(error.localizedDescription)"
        case .libraryLocked: return "Your Library is locked. Unlock it to save."
        }
    }

    /// True only for the locked-vault case, so the alert can offer to unlock
    /// without needing `Equatable` (the `.writeFailed(Error)` payload blocks it).
    var isLibraryLocked: Bool {
        if case .libraryLocked = self { return true }
        return false
    }

    /// Per-case alert title shown by `SaveFeedbackModifier`.
    var alertTitle: String {
        switch self {
        case .libraryLocked: return "Library Locked"
        case .alreadySaved: return "Already Saved"
        case .downloadFailed: return "Download Failed"
        case .writeFailed: return "Couldn't Save"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySaveServiceTests test
```
Expected: PASS (the two new tests plus the three pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibrarySaveService.swift DiffuselyTests/LibrarySaveServiceTests.swift
git commit -m "feat(library): add .libraryLocked save error + alert helpers"
```

---

### Task 2: Pending-retry queue + failure recording on `LibrarySaveService`

**Files:**
- Modify: `Diffusely/Services/Library/LibrarySaveService.swift` (add members near the `@Published` block ~line 87-92; add methods; rewrite `save()`'s catch at lines 167-171)
- Test: `DiffuselyTests/LibrarySaveServiceTests.swift`

**Interfaces:**
- Consumes: `LibrarySaveError.libraryLocked` / `.isLibraryLocked` (Task 1); existing `LibraryBackfillSidecarStoreError.vaultLocked`; existing `save(_:knownPostTitle:knownPublishedAt:)`, `inFlight`, `isSaving(itemID:)`.
- Produces:
  - `struct LibrarySaveService.PendingLockedSave { let image: CivitaiImage; let knownPostTitle: String?; let knownPublishedAt: Date? }`
  - `private(set) var pendingLockedSaves: [PendingLockedSave]`
  - `func recordFailure(_ error: Error, image: CivitaiImage, knownPostTitle: String?, knownPublishedAt: Date?)`
  - `func retryPendingLockedSaves()`
  - `func discardPendingLockedSaves()`
  - `func clearError()`

- [ ] **Step 1: Write the failing tests**

Add to `DiffuselyTests/LibrarySaveServiceTests.swift`, inside the suite. These construct the service directly and call the new methods — no network, no `performSave`:

```swift
// MARK: - Failure recording + pending-retry queue

@Test func recordFailureQueuesPendingAndSetsLockedError() {
    let svc = LibrarySaveService()
    let image = makeImage(id: 301)

    svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                      image: image, knownPostTitle: "My Post", knownPublishedAt: nil)

    #expect(svc.lastError?.isLibraryLocked == true)
    #expect(svc.pendingLockedSaves.count == 1)
    #expect(svc.pendingLockedSaves.first?.image.id == 301)
    #expect(svc.pendingLockedSaves.first?.knownPostTitle == "My Post")
}

@Test func recordFailureDoesNotDuplicatePendingForSameItem() {
    let svc = LibrarySaveService()
    let image = makeImage(id: 302)

    svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                      image: image, knownPostTitle: nil, knownPublishedAt: nil)
    svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                      image: image, knownPostTitle: nil, knownPublishedAt: nil)

    #expect(svc.pendingLockedSaves.count == 1)
}

@Test func recordFailureMapsNonLockedErrorsWithoutQueuing() {
    let svc = LibrarySaveService()
    let image = makeImage(id: 303)

    svc.recordFailure(LibrarySaveError.downloadFailed,
                      image: image, knownPostTitle: nil, knownPublishedAt: nil)
    #expect(svc.lastError?.alertTitle == "Download Failed")
    #expect(svc.pendingLockedSaves.isEmpty)

    let generic = NSError(domain: "test", code: 1)
    svc.recordFailure(generic, image: image, knownPostTitle: nil, knownPublishedAt: nil)
    #expect(svc.lastError?.alertTitle == "Couldn't Save")
    #expect(svc.pendingLockedSaves.isEmpty)
}

@Test func discardAndClearBehaveIndependently() {
    let svc = LibrarySaveService()
    let image = makeImage(id: 304)
    svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                      image: image, knownPostTitle: nil, knownPublishedAt: nil)

    svc.clearError()
    #expect(svc.lastError == nil)
    #expect(svc.pendingLockedSaves.count == 1, "clearError leaves the retry queue intact")

    svc.discardPendingLockedSaves()
    #expect(svc.pendingLockedSaves.isEmpty)
}

@Test func retryPendingLockedSavesDrainsQueueAndRefires() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    // Inject `.locked` so the re-fired save's performSave refuses BEFORE any
    // network download (the locked guard precedes the download). Assertions run
    // synchronously, before the fire-and-forget task body executes.
    let svc = LibrarySaveService(resolveVaultContext: {
        (.locked, LibraryFileStore(itemsDirectory: dir, crypto: nil))
    })
    let image = makeImage(id: 305)
    svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                      image: image, knownPostTitle: nil, knownPublishedAt: nil)
    #expect(svc.pendingLockedSaves.count == 1)

    svc.retryPendingLockedSaves()

    #expect(svc.pendingLockedSaves.isEmpty, "retry drains the queue synchronously")
    #expect(svc.lastError == nil, "retry clears the previous error")
    #expect(svc.isSaving(itemID: 305), "retry re-initiates the save (inFlight synchronously)")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySaveServiceTests test
```
Expected: FAIL — compile error, `recordFailure`/`retryPendingLockedSaves`/`discardPendingLockedSaves`/`clearError`/`pendingLockedSaves` do not exist.

- [ ] **Step 3: Add the queue members**

In `LibrarySaveService`, immediately after the existing published/weak declarations (after `weak var indexService: LibraryIndexService?` — currently line 90), add:

```swift
    /// One queued retry of a save that was refused because the vault was
    /// locked. Held separately from `lastError` so dismissing the alert can
    /// clear the error without dropping a queued retry (see
    /// `SaveFeedbackModifier`). Replayed by `retryPendingLockedSaves()` after a
    /// successful unlock.
    struct PendingLockedSave {
        let image: CivitaiImage
        let knownPostTitle: String?
        let knownPublishedAt: Date?
    }

    @Published private(set) var pendingLockedSaves: [PendingLockedSave] = []
```

- [ ] **Step 4: Add the failure-recording + queue methods**

Add these methods to `LibrarySaveService` (e.g. just before the `// MARK: - Helpers` section, ~line 295):

```swift
    // MARK: - Failure feedback + locked-vault retry queue

    /// Maps a thrown save error onto `lastError` for the app-level alert, and —
    /// for the locked-vault case only — queues the save for replay after unlock.
    /// Internal (not private) so unit tests can drive it without the
    /// fire-and-forget `save()` wrapper or a network download.
    func recordFailure(_ error: Error, image: CivitaiImage,
                       knownPostTitle: String?, knownPublishedAt: Date?) {
        if let storeError = error as? LibraryBackfillSidecarStoreError, storeError == .vaultLocked {
            if !pendingLockedSaves.contains(where: { $0.image.id == image.id }) {
                pendingLockedSaves.append(PendingLockedSave(
                    image: image, knownPostTitle: knownPostTitle, knownPublishedAt: knownPublishedAt))
            }
            lastError = .libraryLocked
        } else if let saveError = error as? LibrarySaveError {
            lastError = saveError
        } else {
            lastError = .writeFailed(error)
        }
    }

    /// Replay every queued locked save (called after a successful unlock). Drains
    /// the queue and clears the error synchronously, then re-fires each save;
    /// `save()`'s own `inFlight` guard dedupes any still-running duplicate.
    func retryPendingLockedSaves() {
        let pending = pendingLockedSaves
        pendingLockedSaves.removeAll()
        lastError = nil
        for item in pending {
            save(item.image, knownPostTitle: item.knownPostTitle, knownPublishedAt: item.knownPublishedAt)
        }
    }

    /// Drop all queued locked saves without replaying them (alert "Not Now",
    /// unlock-sheet cancel, or sheet dismissal).
    func discardPendingLockedSaves() {
        pendingLockedSaves.removeAll()
    }

    /// Clear the surfaced error only, leaving the retry queue intact (the alert's
    /// `isPresented` binding calls this on dismissal so the Unlock path survives).
    func clearError() {
        lastError = nil
    }
```

- [ ] **Step 5: Rewire `save()`'s catch to `recordFailure`**

In `save(_:knownPostTitle:knownPublishedAt:)`, replace the two catch clauses (currently lines 167-171):

```swift
            } catch let error as LibrarySaveError {
                self.lastError = error
            } catch {
                self.lastError = .writeFailed(error)
            }
```

with the single call (the `image`, `knownPostTitle`, `knownPublishedAt` parameters are in scope):

```swift
            } catch {
                self.recordFailure(error, image: image,
                                   knownPostTitle: knownPostTitle, knownPublishedAt: knownPublishedAt)
            }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySaveServiceTests test
```
Expected: PASS — all Task 1 + Task 2 tests plus the three pre-existing `performSave*` tests.

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Services/Library/LibrarySaveService.swift DiffuselyTests/LibrarySaveServiceTests.swift
git commit -m "feat(library): queue+replay locked saves; route all save failures through recordFailure"
```

---

### Task 3: `SaveFeedbackModifier` + `SaveUnlockSheet`

**Files:**
- Create: `Diffusely/Views/SaveFeedbackModifier.swift`

**Interfaces:**
- Consumes: `LibrarySaveService.shared` (`lastError`, `pendingLockedSaves`, `retryPendingLockedSaves()`, `discardPendingLockedSaves()`, `clearError()`, plus `LibrarySaveError.isLibraryLocked`/`.alertTitle`/`.errorDescription` from Tasks 1-2); `LibraryVaultProvider.shared` (`state: LibraryVault.State`); existing `LibraryUnlockView(provider:)`.
- Produces: `func View.saveFeedback() -> some View` (consumed by Task 4).

**Note:** SwiftUI views are verified by compilation on both platforms (no unit test), consistent with the rest of `Diffusely/Views`. The correctness of the underlying state transitions is already covered by Task 2's tests.

- [ ] **Step 1: Create the file**

Create `Diffusely/Views/SaveFeedbackModifier.swift` with exactly:

```swift
import SwiftUI

/// App-level presenter for `LibrarySaveService` failures. Applied once at the
/// ContentView root (per platform branch) so it covers every "Save to Library"
/// call site — the feed cell, image detail, post detail, and author grid — all
/// of which fire through the shared `LibrarySaveService.shared` singleton.
///
/// Those failures set `LibrarySaveService.lastError` but nothing rendered it
/// before. This modifier surfaces every save failure as an alert. The
/// locked-vault case additionally offers to unlock: its "Unlock" button
/// presents the existing `LibraryUnlockView` in a sheet, and on a successful
/// unlock the save(s) the user attempted re-fire automatically.
///
/// Pending retries live in `LibrarySaveService.pendingLockedSaves` — a property
/// independent of `lastError` — so the alert's `isPresented` binding can clear
/// `lastError` on any dismissal without ever dropping a queued retry.
struct SaveFeedbackModifier: ViewModifier {
    @ObservedObject private var saveService = LibrarySaveService.shared
    @ObservedObject private var vaultProvider = LibraryVaultProvider.shared
    @State private var showUnlockSheet = false

    func body(content: Content) -> some View {
        content
            .alert(
                saveService.lastError?.alertTitle ?? "",
                isPresented: errorPresented,
                presenting: saveService.lastError
            ) { error in
                if error.isLibraryLocked {
                    Button("Unlock") { showUnlockSheet = true }
                    Button("Not Now", role: .cancel) {
                        saveService.discardPendingLockedSaves()
                    }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { error in
                Text(error.errorDescription ?? "")
            }
            .sheet(isPresented: $showUnlockSheet, onDismiss: {
                // Idempotent cleanup: after a successful unlock the retry has
                // already drained the queue (no-op here); after a swipe-dismiss
                // this drops the queued save.
                saveService.discardPendingLockedSaves()
            }) {
                SaveUnlockSheet(
                    provider: vaultProvider,
                    onUnlocked: {
                        saveService.retryPendingLockedSaves()
                        showUnlockSheet = false
                    },
                    onCancel: { showUnlockSheet = false }
                )
            }
    }

    /// Drives the alert off `lastError`; clears only the error on dismissal so
    /// the retry queue survives for the Unlock path.
    private var errorPresented: Binding<Bool> {
        Binding(
            get: { saveService.lastError != nil },
            set: { presented in if !presented { saveService.clearError() } }
        )
    }
}

/// The unlock sheet shown from a locked-vault save. Wraps the existing,
/// unmodified `LibraryUnlockView` and watches the vault state: when it flips
/// off `.locked`, `onUnlocked` fires (replaying the queued save and closing the
/// sheet). `LibraryUnlockView`'s own `.task` auto-attempts Face ID / Touch ID
/// on appear, so no unlock logic is duplicated here.
private struct SaveUnlockSheet: View {
    @ObservedObject var provider: LibraryVaultProvider
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            LibraryUnlockView(provider: provider)
                .navigationTitle("Unlock Library")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                }
        }
        .onChange(of: provider.state) { _, newState in
            if newState != .locked { onUnlocked() }
        }
    }
}

extension View {
    /// Attaches the app-level save-failure alert + unlock sheet. Apply once at
    /// the app root; every `LibrarySaveService.shared` call site is covered.
    func saveFeedback() -> some View {
        modifier(SaveFeedbackModifier())
    }
}
```

- [ ] **Step 2: Verify it builds on iOS**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Expected: BUILD SUCCEEDED. (Nothing references `saveFeedback()` yet; this just confirms the new file compiles.)

- [ ] **Step 3: Verify it builds on macOS**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED (confirms the `#if os(iOS)` guard around `navigationBarTitleDisplayMode` is correct).

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/SaveFeedbackModifier.swift
git commit -m "feat(library): add SaveFeedbackModifier alert + in-place unlock sheet"
```

---

### Task 4: Wire `.saveFeedback()` into `ContentView`

**Files:**
- Modify: `Diffusely/ContentView.swift` (macOS branch ~line 106; iOS branch ~line 157)

**Interfaces:**
- Consumes: `View.saveFeedback()` (Task 3).
- Produces: nothing (terminal wiring).

- [ ] **Step 1: Attach to the macOS branch**

In `ContentView.body`, the macOS `NavigationSplitView { … }` currently ends with:

```swift
        .task { await startLibrarySubsystem() }
        #else
```

Insert `.saveFeedback()` right after that `.task` line (before `#else`):

```swift
        .task { await startLibrarySubsystem() }
        .saveFeedback()
        #else
```

- [ ] **Step 2: Attach to the iOS branch**

In the iOS `TabView { … }`, the closing modifier is currently:

```swift
        .task { await startLibrarySubsystem() }
        #endif
```

Insert `.saveFeedback()` right after that `.task` line (before `#endif`):

```swift
        .task { await startLibrarySubsystem() }
        .saveFeedback()
        #endif
```

- [ ] **Step 3: Verify it builds on iOS**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify it builds on macOS**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run the full unit-test suite (regression check)**

Run:
```bash
xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests test
```
Expected: PASS. (`-only-testing:DiffuselyTests` excludes `DiffuselyUITests` deliberately.)

- [ ] **Step 6: Commit**

```bash
git add Diffusely/ContentView.swift
git commit -m "feat(library): present save feedback at the app root on both platforms"
```

---

## Manual verification (after all tasks)

With a configured Library encryption vault that is currently **locked** (relaunch the app so the vault is locked, or lock it), on the iOS Simulator and/or macOS:

1. Browse a feed and tap **Save to Library** on an image → the **Library Locked** alert appears with **Unlock** / **Not Now**.
2. Tap **Unlock** → the unlock sheet (`Unlock Library`) appears (Face ID is auto-attempted; password/recovery available).
3. Unlock successfully → the sheet dismisses and the image appears in the Library (auto-retry worked).
4. Repeat, but tap **Not Now** (or swipe the sheet away) → nothing is saved and no state lingers (a subsequent successful unlock from the Library tab does **not** trigger a surprise save).
5. Sanity: with encryption **off** (or unlocked), saving behaves exactly as before — no alert on success.

---

## Self-Review

- **Spec coverage:** `.libraryLocked` case + helpers (Task 1); `recordFailure` mapping all errors + `pendingLockedSaves` + retry/discard/clearError + `save()` rewire (Task 2); `SaveFeedbackModifier`/`SaveUnlockSheet`/`saveFeedback()` with alert, Unlock offer, in-place sheet, auto-retry, race-safe binding (Task 3); ContentView wiring on both platforms (Task 4); tests (Tasks 1-2) and manual verification steps. "Surface all save errors" is covered by `recordFailure` + the non-locked alert branch. All spec sections map to a task.
- **Placeholder scan:** none — every step has concrete code or an exact command.
- **Type consistency:** `recordFailure`, `retryPendingLockedSaves`, `discardPendingLockedSaves`, `clearError`, `pendingLockedSaves`, `PendingLockedSave`, `isLibraryLocked`, `alertTitle`, `saveFeedback()` are named identically in their defining task and every consuming task. `provider.state` is `LibraryVault.State` (Equatable, cases `notConfigured/locked/unlocked`), matching the `.onChange`/`!= .locked` usage. `save(_:knownPostTitle:knownPublishedAt:)` signature matches the retry call site.
```
