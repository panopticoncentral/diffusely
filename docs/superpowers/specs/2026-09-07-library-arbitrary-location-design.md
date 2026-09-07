# Open the Library at an Arbitrary Location (macOS)

**Date:** 2026-09-07
**Status:** Approved design, ready for implementation plan

## Problem

The personal Library is hardwired to the app's iCloud Drive ubiquity container.
`LibraryContainer.itemsDirectory()` resolves either that container or, when iCloud
is unavailable, a hidden Application Support fallback that exists only to be
migrated back into iCloud at the first opportunity. The user has no say in where
their Library lives.

The export feature (2026-09-05) closed half of this gap: it writes a complete
plaintext copy of the Library to a chosen folder, and `LibraryExporter` deliberately
writes it *in the app's own layout* — `<id>.json`, `<id>.<ext>`,
`album-<uuid>.json` — with an explicit note that "the folder is meant to stay usable
as a Library later". The export spec's own Problem section names the destination
this feature reaches: "Moving the Library somewhere else — a OneDrive folder
encrypted by Cryptomator, say, dropping the need for in-app encryption entirely."

This feature is the other half: **point the app at an arbitrary folder and use it as
the Library**. An exported folder opens in place with no conversion step.

At-rest encryption exists because an iCloud container is storage the user does not
control. A folder the user chose is storage they *do* control — Cryptomator,
FileVault, an encrypted volume, whatever they already trust. So a custom location is
unconditionally plaintext, and the in-app vault is an iCloud-only concern.

**Constraint: a custom root is local storage.** Confirmed with the user — custom
roots are local volumes only, never a provider-synced folder (OneDrive, Dropbox).
Those providers can present dataless placeholders much as iCloud does, but without
the ubiquitous APIs the app uses to detect and materialize them, so the design would
have to grow a whole second materialization story to support them. It does not: a
custom root is treated as always-local, and that is a supported-configuration
boundary rather than an assumption to defend in code.

**Scope: macOS only.** Same reasoning as export — the Mac app is unsandboxed, so a
folder URL from `NSOpenPanel` needs no security-scoped bookmark plumbing, and a
folder picker is a native idiom there. iOS keeps using iCloud unchanged.

## Key findings

- **`LibraryContainer.itemsDirectory()` is a true single seam.** All ~20 call sites
  across `LibraryStore`, `LibraryIndexService`, `LibraryImageRequest`,
  `LibraryMediaLoader`, `LibrarySaveService`, `LibraryEncryptionCoordinator` and the
  views go through it. Changing what it resolves changes the whole app.
- **Non-iCloud code paths are already live**, not new. The local fallback means
  `LibraryIndexService` already carries "non-ubiquitous local file that exists =
  downloaded" branches (`LibraryIndexService.swift:738,1056`) and
  `LibraryFileMaterializer` already declines to materialize non-ubiquitous targets
  (`LibraryFileMaterializer.swift:45`).
- **`LibraryContainer.isICloudBacked` already exists** as a resolved-root property;
  the capability table below generalizes it rather than inventing a new concept.
- **The app is not sandboxed** (`Diffusely.entitlements` carries only iCloud keys),
  confirmed by `LibraryExportPanel`'s own comment. A stored path suffices; a
  security-scoped bookmark would be dead weight.
- **`vaultURLs()` derives its location by `deletingLastPathComponent()`** on the
  items directory. That is correct for the iCloud layout (`Documents/Items/` → vault
  in `Documents/`) and actively wrong for a flat custom root, where it would resolve
  to the *parent* of the user's chosen folder.
- **`itemsDirectory()` unconditionally calls `createDirectory(withIntermediateDirectories:)`.**
  Against an unmounted volume that silently creates an empty directory at the mount
  point — which reconcile would then treat as an authoritative empty Library.
- **`PersistedLibraryItem.itemID` is `@Attribute(.unique)`**, so two libraries
  cannot coexist in the index without a schema migration. The index is a disposable
  mirror of exactly one folder.
- **Eviction uses `evictUbiquitousItem`**, a no-op on a plain file. So the cache
  limit cannot destroy data at a custom root — but it also cannot do anything there,
  and a control that silently does nothing is worse than an absent one.
- **`LibraryVaultProvider.LibraryGate` is the single blocking gate** the Library tab,
  `LibraryStore.shouldAutonomousReconcile` and the Settings rebuild-reason helper all
  switch on exhaustively. `SettingsView.swift:386` documents that exhaustiveness as
  deliberate: a new case must be a compile error at every site that has to handle it.

## Decisions

Settled during brainstorming, recorded so the plan does not relitigate them:

| Question | Decision |
|---|---|
| Semantics | **Switch the active Library.** One Library at a time; the root is a remembered setting. Not a second library, not a read-only viewer. |
| Platform | **macOS only.** |
| Encryption at a custom root | **Forbidden**, not merely off. No `vault.json` is ever written outside the iCloud container. |
| Index on switch | **Wipe and rebuild.** No schema migration, no per-root namespacing. |
| Applying a switch | **Hot-swap in place.** No relaunch prompt. |
| Missing root at launch | **Block with an explicit state.** Never silently fall back to iCloud; never reconcile against a missing root. |
| External change detection | **Watch the folder** and feed the existing debounced `ReconcileScheduler`. |

## Architecture

### `LibraryRoot`

```swift
enum LibraryRoot: Equatable {
    case iCloud
    case custom(URL)
}
```

Persisted in `UserDefaults` as a plain path string under `library_root_path`; an
absent value means `.iCloud`. Not a security-scoped bookmark (the app is
unsandboxed), and a readable path is also what the `rootUnavailable` UI needs to
show the user.

### `LibraryRootStore`

New type owning persistence, validation and capabilities. Pure enough to test
directly.

**Validation** (`validate(_ url: URL) -> Result<Void, LibraryRootError>`):

| Condition | Result |
|---|---|
| Does not exist, or is a file | `.notADirectory` |
| Not writable | `.notWritable` |
| Contains `vault.json`, or any `.m` / `.b` / `.x` file | `.encryptedLibrary` |
| Is the iCloud container's items directory | `.isICloudContainer` |
| Empty directory | **valid** — "start a new Library here" |

`.encryptedLibrary` exists so an encrypted folder cannot open as a mysteriously
empty Library. The message states that encrypted Libraries live only in iCloud.

### Layout: the chosen folder *is* the items directory

Flat `<id>.json` / `<id>.<ext>` / `album-<uuid>.json`, exactly what `LibraryExporter`
writes. No `Items/` subfolder is created inside the user's folder. This is what lets
an export destination open in place.

Consequences:

- `vaultURLs()` **fails for `.custom`** rather than resolving into the parent
  directory.
- `LibraryVaultProvider` **skips vault bootstrap entirely** for a custom root:
  `vault` stays `nil`, which existing code already treats as `.notConfigured` →
  passthrough store → gate `.browsable`. The iCloud vault is untouched and returns
  intact on switching back.
- `itemsDirectory()` **must not create** a custom root. Existence is required;
  absence is an error, not something to repair.
- The exporter's failures file is `library-export-failures.txt`, deliberately not
  `.json`, so it is not enumerated as an item. No change needed.

### Capabilities by root

Derived in one place from the active root:

| | `.iCloud` | `.custom` |
|---|---|---|
| At-rest encryption | available | forbidden; Settings row disabled with reason |
| Change detection | `NSMetadataQuery` | `DispatchSource` folder watcher |
| Materialization + download banner | on | off — files are always local |
| Cache limit / Free Up Space | on | hidden — eviction is a no-op there |
| Local→iCloud item migration | on | never runs |

### Root generation counter

**The central data-safety mechanism.** A reconcile scan of the *old* root that
finishes after a switch would apply its results to the *new* root's index and prune
every row it did not see. The scan runs on `LibraryIndexService`'s own dispatch
queue, so cancelling triggers cannot stop one already in flight.

`LibraryContainer` therefore holds a monotonic `rootGeneration`, incremented on every
switch. A reconcile captures the generation it began under; results whose generation
no longer matches are **discarded at apply time** rather than applied. Late work
becomes inert instead of destructive.

This is the same failure shape as the iCloud eviction-sweep class of bug — "I did not
see the files, therefore they are gone" — and it is closed structurally rather than by
careful ordering.

### `LibraryRootCoordinator`

`@MainActor`, mirroring the existing `LibraryEncryptionCoordinator`. Owns the switch:

1. **Validate** the target. On failure, nothing changes at all.
2. **Block** the Library: `LibraryGate` gains `case switchingRoot`, honoured with top
   precedence in `recomputeGate()`.
3. **Quiesce**: cancel the `ReconcileScheduler`, stop the `NSMetadataQuery` or folder
   watcher, bump `rootGeneration`.
4. **Flip**: persist the root, clear `LibraryContainer`'s cached directory.
5. **Re-bootstrap `LibraryVaultProvider`**. Custom → no vault → `.browsable`. Back to
   iCloud → whatever `vault.json` says, so a locked vault correctly shows the unlock
   gate again.
6. **Wipe and rebuild** the index against the new root, behind the progress UI the
   migration flow already uses.
7. **Restart** the change detection the new root calls for, restart `LibraryStore`,
   release the gate.

### Blocked states

`LibraryGate` gains two cases, both of which make `shouldAutonomousReconcile` return
`false`:

- `switchingRoot` — progress view.
- `rootUnavailable(URL)` — "Library not found at `<path>`", with **Locate…** and
  **Switch back to iCloud**. Reached when a saved custom root is missing at launch
  (unplugged drive, renamed folder, unmounted sync provider) *and* when a switch
  fails partway through.

A failed switch deliberately does **not** silently revert: a half-built index paired
with a quietly-restored old root is the worst available outcome. It lands in
`rootUnavailable` naming what failed, with the same two recovery buttons.

The associated `URL` is stable, so `LibraryView`'s `.task(id: libraryGate)` does not
churn on it.

## UI

All macOS-only (`#if os(macOS)`):

- **Settings → Personal Library → Library Location**: shows "iCloud Drive" or the
  folder path, with **Choose Folder…** and **Use iCloud**. Picker is a sibling of
  `LibraryExportPanel` with its own prompt and message.
- **Confirmation before switching**, naming both consequences: the index is rebuilt
  now, and encryption is unavailable at a custom location.
- **Library Encryption row disabled** at a custom root, with the reason inline —
  the pattern the rebuild-reason helper already uses.
- **Cache limit and Free Up Space hidden** at a custom root.
- **Reset Library's confirmation names the path** at a custom root. The action
  deletes the contents of the items directory, which there is the user's own folder.
- **Two new gate views** in the Library tab for `switchingRoot` and
  `rootUnavailable`.
- **iCloud download banner suppressed** at a custom root.

## Testing

Pure logic wherever possible, matching how the encryption work was structured. All
tests use temp directories; the `isRunningInTestHost` guard in
`LibraryVaultProvider` keeps the suite away from the real container and nothing here
weakens it.

- Root persistence round-trip; absent value defaults to `.iCloud`.
- `LibraryRootStore.validate` across the full table above, including
  empty-folder-is-valid.
- **Generation counter**: a reconcile result carrying a stale generation is discarded
  rather than applied. The apply path gets a pure static seam in the style of the
  existing `shouldAutonomousReconcile`. This is the highest-value test in the
  feature.
- Gate precedence: `switchingRoot` and `rootUnavailable` outrank every vault state,
  and both make `shouldAutonomousReconcile` false; Settings reason strings exist for
  both.
- `LibraryContainer`: `.custom` never creates its directory, `.iCloud` still does,
  `vaultURLs()` fails for `.custom`.
- Folder watcher against a temp directory: create / modify / delete schedules exactly
  one debounced reconcile.
- Switch ordering with fakes: quiesce and generation bump precede the flip; wipe
  precedes rebuild.

Per `xcodebuild-test-quirks`: run with `-parallel-testing-enabled NO`. macOS-only
production code is `#if os(macOS)`-guarded, and its tests with it.

## Risks

- **The real Library is ~6,500 encrypted items in iCloud.** The switch path tears
  down and re-bootstraps the vault. Verify the full round trip — iCloud → custom →
  back to iCloud, vault intact and unlockable — against a seeded fake library first,
  exactly as the encryption feature was verified, before pointing it at real data.
- **The folder watcher fires on the app's own writes**, so a save will schedule a
  reconcile of work already applied. The existing 750ms debounce absorbs bursts and a
  redundant reconcile is idempotent, so this is accepted rather than filtered.

## Out of scope

- iOS support (needs `UIDocumentPicker` plus security-scoped bookmarks around every
  Library read and write).
- Multiple libraries open at once, or a recents list of libraries.
- Encryption at a custom root.
- Provider-synced folders as custom roots (OneDrive, Dropbox and friends). Out of
  scope by the constraint above, not merely untested.
- Moving or copying data between roots. Switching re-points the app; it never
  relocates files. Use Export to produce a folder, then switch to it.
