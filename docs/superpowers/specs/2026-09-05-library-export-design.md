# Export Library (macOS)

**Date:** 2026-09-05
**Status:** Approved design, ready for implementation plan

## Problem

The personal Library lives in the app's iCloud Drive ubiquity container, encrypted
at rest (`.m` / `.b` / `.x` opaque names). There is no way to get a copy of it out.
That matters for two reasons:

1. **No backup.** The only copy of thousands of saved items is a single iCloud
   container that macOS actively evicts under disk pressure, and that a bad
   reconcile or a vault problem could damage. Nothing outside the app can read it.
2. **No exit.** Moving the Library somewhere else — a OneDrive folder encrypted by
   Cryptomator, say, dropping the need for in-app encryption entirely — is
   currently impossible because there is no way to produce a plaintext copy of the
   container.

The goal is a **complete, decrypted, restorable archive** of the Library written to
a folder the user chooses. Browsing convenience is explicitly not the goal;
fidelity is.

This is macOS-only. The feature only makes sense where the whole Library can be
downloaded and written to arbitrary local storage, and where a folder picker is a
native idiom.

## Key findings

- The app is **not sandboxed** (`Diffusely.entitlements` carries only iCloud keys,
  no `com.apple.security.*`), so `NSOpenPanel` needs no security-scoped bookmark
  plumbing and the destination URL stays usable for the whole run.
- **Zero prior art for folder export**: no `NSOpenPanel`, no `NSSavePanel`, no
  `.fileImporter` anywhere in the tree. The one `.fileExporter` use
  (`ComfyRecipeView.swift:43`, backed by `Utilities/DataDocument.swift`) is
  single-file only and not reusable here.
- Container media extensions are **cosmetic**. `LibrarySaveService.swift:60,76`
  and `LibraryIndexService.swift:634` always derive the on-disk name from
  `metadata.mediaType.fileExtension`, which is literally `"jpeg"` or `"mp4"`.
  Because Civitai's `original=true` returns uploader bytes verbatim, a container
  `<id>.jpeg` is frequently really PNG or WebP. Nothing in the app reads
  `mediaFileName` to locate a file.
- `LibraryItemMetadata.contentSHA256` is **non-optional** on every sidecar, so
  integrity verification during export costs only the hash of bytes already read.
- `LibraryFileMaterializer.download` (`LibraryFileMaterializer.swift:44`) kicks
  `startDownloadingUbiquitousItem` then polls 500 ms × 240 (a ~2 minute ceiling)
  and reports **no byte-level progress**. Called serially it keeps exactly one
  iCloud request in flight.
- `LibraryEncryptionMigrator.materializeIfNeeded` (`:263`) documents the sanctioned
  idiom for bridging the async materializer into a dedicated blocking thread via
  `DispatchSemaphore` — safe precisely because it never blocks a cooperative-pool
  thread.
- Album **membership** is on the item sidecar (`LibraryItemMetadata.albumIDs`, the
  source of truth); `album-<uuid>.json` aux files carry only name, description and
  AI profile. The aux namespace is shared with sort-assistant state, which must be
  classified out by decoding.
- The SwiftData index is a disposable cache the app rebuilds on demand, but it
  already carries `fileByteSize` and `downloadStatusRaw` per item — the only way to
  size a download estimate without a full container walk.

## Decisions

Settled during design, with the reasoning that constrains implementation:

1. **Purpose is archive/backup**, not handoff to other tools. Fidelity beats
   browsability wherever they conflict.
2. **Decrypted, in the app's plaintext layout.** Not an encrypted byte copy (needs
   the vault key, readable by nothing) and not a friendlier layout. Security moves
   to the destination — Cryptomator, FileVault, whatever the user chooses.
3. **Resumable full export, no prune.** Every run walks everything and skips what
   is already present. It never deletes exported files for items since removed from
   the Library. A mirror that deletes is a foot-gun for a backup; prune can be added
   later once the export is trusted.
4. **Download missing items, after informed consent.** Non-materialized items are
   counted and sized up front, and nothing starts until the user confirms. A backup
   with silent holes is not a backup; an unannounced 38 GB download is not
   acceptable either.
5. **Container-faithful filenames** — `<id>.jpeg` / `<id>.mp4`, matching the
   sidecar's `mediaFileName`. A PNG named `.jpeg` is cosmetically wrong but opens
   correctly in Finder, Preview and Quick Look, all of which sniff content. The
   alternative — sniffing via `MediaContainer.detect` and rewriting `mediaFileName`
   — would produce an archive the app itself could not read back, since it locates
   media by `mediaType.fileExtension`. Only the faithful layout keeps the future
   "point Diffusely at this folder" migration free.
6. **Synchronous engine plus a thin coordinator**, mirroring
   `LibraryEncryptionMigrator` / `LibraryEncryptionCoordinator`. An `actor`-based
   async engine would put coordinated reads and AES-GCM opens on the cooperative
   pool — the "grey spinner" starvation bug class this repo has hit repeatedly —
   and would need per-call continuation bridges anyway. Extending the migrator
   itself was rejected: it is stop-on-first-failure, in-place, crash-safety-critical
   code whose job is to never corrupt the live Library, and an export is strictly a
   reader.

## Scope

In scope:

1. `LibraryExporter` — synchronous, nonisolated export engine.
2. `LibraryExportPlan` — pre-flight counting, sizing and free-space check.
3. `LibraryExportService` — `@MainActor ObservableObject` coordinator.
4. macOS File-menu command, `NSOpenPanel` folder picker, progress sheet.
5. Unit tests for the engine and the plan.

Out of scope: prune of deleted items; scheduled or automatic export; iOS/iPadOS
entry point; any change to how the live Library is written; re-import of an
exported folder as a Library (the layout makes it possible; the feature is not
built here).

## Output layout

Written directly into the chosen folder — no wrapper subfolder, so re-running into
the same folder is the resume case:

```
<chosen folder>/
  12345.jpeg          media, container-faithful extension
  12345.json          sidecar, plaintext, verbatim decrypted bytes
  67890.mp4
  67890.json
  album-<uuid>.json   album name / description / AI profile
```

This is byte-for-byte the app's plaintext container layout, so the folder is a
valid Diffusely Library as-is.

- **`vault.json` is never exported.** The archive is decrypted; the key would be
  meaningless beside it and shipping it next to plaintext media is a security
  downgrade.
- **`_DiffuselyExport-failures.txt`** is written only when at least one item
  failed, listing item IDs and reasons. It describes the most recent run only: any
  existing copy is deleted when a run starts, so a clean run leaves no stale file
  claiming failures that have since been resolved. Nothing else is added, so the
  folder stays usable as a Library later.

## Architecture

### New files

| File | Role |
|---|---|
| `Services/Library/Export/LibraryExporter.swift` | The engine. Nonisolated, synchronous. No vault, no UI, no SwiftData. |
| `Services/Library/Export/LibraryExportPlan.swift` | Pre-flight: what will be written, what must be downloaded, how many bytes. |
| `Services/Library/Export/LibraryExportService.swift` | `@MainActor ObservableObject`: vault resolution, `exportQueue`, `Phase`, cancellation. |
| `Views/LibraryExportSheet.swift` | macOS-only. Confirmation → progress → summary. |
| `Utilities/LibraryExportPanel.swift` | macOS-only `NSOpenPanel` wrapper. |

### Edits to existing files

- `DiffuselyApp.swift` — an `ExportCommands` struct inside the existing
  `#if os(macOS)` block, added to the `.commands` list.
- `ContentView.swift` — an `ExportLibraryKey` focused-value alongside
  `SidebarSelectionKey`.
- `LibraryView.swift` — publishes the action via `.focusedSceneValue` and hosts the
  sheet.

### Boundaries

`LibraryExporter` takes a source `LibraryFileStore`, a destination `URL` and
callbacks. It knows nothing about vaults, SwiftData or SwiftUI, which is what makes
it directly testable against temp plaintext and encrypted stores in the manner of
`LibraryEncryptionMigratorTests`.

`LibraryExportService` owns everything the engine deliberately does not: it
resolves `LibraryVaultProvider.reconcileContext()` exactly once (closing the
documented TOCTOU race), guards `state != .locked`, dispatches to a dedicated
serial `exportQueue`, coalesces progress onto the main actor, and owns
cancellation. It follows `SortAssistantService`'s `runTask` + `cancel()` shape and
`LibraryEncryptionCoordinator`'s `Phase` + `runOnIOQueue` shape.

Per repo convention the service exposes a `resolveVaultContext` closure seam
defaulting to `LibraryVaultProvider.shared`, matching `SortAssistantScanner:17`,
`LibraryAlbumService:32` and friends, so tests never touch the shared vault.

## Algorithm

### Enumeration is hybrid

- **What gets exported** comes from `store.enumerateMetadataFiles()` — the
  container, the source of truth. A backup must not inherit the index's gaps.
- **The pre-flight estimate** comes from the SwiftData index, which already holds
  `fileByteSize` and `downloadStatusRaw` per item. This makes the confirmation
  numbers instant instead of requiring a full container walk before the user can
  even see the dialog.
- If the two disagree the run still exports everything the container has, and the
  summary reports the delta ("6 items on disk weren't in the index").

### Pre-flight (`LibraryExportPlan`)

One `contentsOfDirectory` on the destination, one index fetch, then:

- items to export, and items already present (both `<id>.<ext>` and `<id>.json`
  found) to be skipped;
- estimated iCloud download in bytes — the sum of `fileByteSize` over
  not-already-exported items whose `downloadStatus == .evicted`;
- estimated bytes to write — the sum of `fileByteSize` over **all**
  not-already-exported items, whether or not they are currently materialized. This,
  not the download figure, is what the free-space check compares against;
- free space on the destination volume, refusing to start when the bytes-to-write
  figure does not fit.

### Per-item loop

Runs serially on `exportQueue`. Steps 1–3 are performed by the read-ahead cursor
described under "the sliding prefetch window" below, which hands the write cursor
an already-decoded record; steps 4–7 are the write cursor's work. Each item is
therefore decoded exactly once, never twice.

1. Cancellation check.
2. Materialize, read and decrypt the sidecar; decode it to learn `itemID` and
   `mediaType`, and keep the raw decrypted bytes for verbatim writing.
3. Skip if both `<id>.<ext>` and `<id>.json` already exist at the destination.
4. Materialize the media from iCloud — the expensive step.
5. Read and decrypt the media bytes.
6. SHA-256 the bytes; compare against `metadata.contentSHA256`.
7. Write media, then sidecar.

Three properties of that loop are load-bearing:

**Sidecars are written verbatim, never re-encoded.** A copy is decoded in memory to
learn the item's id and extension, but the bytes that land on disk are the exact
decrypted container bytes. A decode → re-encode round trip would silently drop any
field the current `LibraryItemMetadata` struct does not know about — unacceptable
in an archive whose whole purpose is fidelity, and a real risk given the sidecar
schema is already at version 6.

**Every file is written temp-then-rename** (`.<name>.partial`, then an atomic
replace). A killed or cancelled run therefore never leaves a truncated file under a
real name, which is exactly what makes skip-if-exists trustworthy on the next run.
Stale `.partial` files are swept at the start of each run.

**A hash mismatch is exported anyway, and reported.** The instinct is to refuse to
write bytes that do not match `contentSHA256`. But this is a backup, and the
container's copy may be the only other copy in existence — refusing to save it
converts "one suspect copy" into "one suspect copy and no backup". The file is
written and listed in the failures file as an integrity mismatch, so the user knows
which files to distrust.

### Album files

Exported after the items: enumerate the aux namespace, decode each as a
`LibraryAlbumFile`, skip the sort-assistant state that shares that namespace, and
write `album-<uuid>.json`.

### Throughput: the sliding prefetch window

Called straight from a serial loop, `LibraryFileMaterializer.download` keeps one
iCloud request in flight, so throughput is bound by per-file latency rather than
bandwidth. Across thousands of evicted items that is the difference between a long
afternoon and a very long weekend.

The loop therefore runs two cursors over one work list, adding no concurrency to
the write path:

- A **read-ahead cursor** runs up to `K = 16` items in front doing only cheap,
  non-blocking work: materialize and decode the sidecar, then fire
  `startDownloadingUbiquitousItem` on that item's media file and move on without
  waiting. (The media URL is only derivable once the sidecar yields the `itemID`,
  since encrypted names are HMAC tokens over it — hence sidecar-first.)
- The **write cursor** does the real work — wait for materialization, decrypt,
  hash, write — strictly one item at a time, in order.

By the time the write cursor arrives, the OS has usually already pulled the file
down in parallel with the previous fifteen. Writes, decryption and progress
accounting stay perfectly serial, so none of the ordering or contention questions a
full `TaskGroup` export would raise ever arise.

### Concurrency rules observed

- The export runs on a dedicated serial `exportQueue` (`.utility`), never on the
  cooperative pool: coordinated I/O, iCloud waits and AES-GCM opens all block.
- Async materializer calls are bridged with the `DispatchSemaphore` idiom
  documented at `LibraryEncryptionMigrator.swift:263`, which only ever blocks the
  export thread.
- `(state, crypto)` is resolved once up front via `reconcileContext()` and the
  resulting `LibraryFileStore` — a `Sendable`-friendly struct over a URL plus
  `Sendable` crypto — is passed into the queue closure.
- The Mac is kept awake for the run via
  `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated])`,
  released when it ends. This prevents idle sleep only; closing the lid still
  suspends.

## Error handling

Two tiers, deliberately separated.

**Setup failures** abort before anything is written and are the only route to the
`.failed` state: vault locked, destination unwritable, destination inside the
iCloud container, insufficient free space. Each carries a specific reason string
rather than a generic error, following the `SettingsView.rebuildIndexUnavailableReason`
convention of never silently disabling or vaguely failing.

The **destination guard** matters: exporting into the container (or any subfolder
of it) would have the app scanning its own export as new items. It is refused up
front.

**Per-item failures** are collected and never fatal — sidecar unreadable or
undecodable, media file missing, iCloud download timed out or errored, decrypt
failed, integrity mismatch (exported anyway), write failed. Each becomes an
`ExportFailure(itemID, reason)`, counted in the summary and listed in
`_DiffuselyExport-failures.txt`.

This is the opposite of the encryption migrator's stop-on-first-failure, and
intentionally so: the migrator mutates the live Library, whereas an export that
aborts at item 400 of 6,500 because one file is unreachable is worse than useless.
Re-running picks up exactly what is missing.

**Cancellation** is checked between items and inside the download poll, so Cancel
responds in about half a second rather than after a 2-minute timeout. A cancelled
run leaves a valid, resumable partial export.

## User interface

`ExportCommands` joins the existing `#if os(macOS)` block in `DiffuselyApp.swift`
using `CommandGroup(after: .importExport)` — the standard File-menu slot — with
"Export Library…" on ⇧⌘E. It follows the same shape as the three command groups
already there: `@FocusedValue(\.exportLibrary)` plus `.disabled(action == nil)`.

`LibraryView` publishes that focused value **only when
`vaultProvider.libraryGate == .browsable`**, so the menu item greys out
automatically when the vault is locked, still migrating, or not yet loaded — no
separate enablement logic, and no path to the panel from a state where the export
would fail.

Flow: menu → `NSOpenPanel` (directories only, `canCreateDirectories`, "Export" as
the prompt) → sheet on the Library window. Five states mirroring `Phase`:

1. **Preparing** — brief spinner while the plan is built.
2. **Confirm** — the informed-consent step:

   > Export 6,214 items to **Diffusely Backup**.
   > 5,980 items need downloading from iCloud — about **38.2 GB**.
   > 234 items are already exported and will be skipped.
   > 41.6 GB available on the destination volume.

   with Cancel and Export.
3. **Exporting** — determinate `ProgressView(value:total:)`, "1,204 of 6,214", a
   secondary line naming the current step (downloading vs. writing), and Cancel.
4. **Done** — exported / skipped / failed counts, Reveal in Finder, and when
   anything failed a pointer to `_DiffuselyExport-failures.txt`.
5. **Failed** — setup-level refusals only.

Borrowed from `SortAssistantSheet`, the closest existing long-task sheet:
`.interactiveDismissDisabled()` while running, `onDisappear { service.cancel() }`
so dismissing never orphans a background run, and an explicit `.frame(minWidth: 420)`
because macOS sheets size to ideal content height.

Progress updates are **throttled to roughly 10/sec**. The engine reports every
item; the service coalesces. The migrator hops to the main actor once per item,
which is fine for a few hundred and needless churn at 6,500.

## Testing

The engine takes a `LibraryFileStore` and a destination URL and nothing else, so
all of it tests against temp directories in the manner of
`LibraryEncryptionMigratorTests`.

`LibraryExporterTests`:

- Export from a plaintext store and from an encrypted store produce identical
  output.
- Sidecar bytes on disk are byte-identical to the container's decrypted bytes.
- Re-running skips completed items and writes nothing new.
- An interrupted run leaves no file under a real name; a stale `.partial` is swept
  and the item re-exported.
- A hash mismatch is reported and the file is still written.
- Album aux files are exported; sort-assistant state in the same namespace is
  skipped.
- Cancellation mid-run leaves a valid, resumable partial export.
- A destination inside the container is refused.

`LibraryExportPlanTests`: already-exported detection, download estimate, free-space
refusal.

The sheet and menu command are not unit-tested. Per the standing rule,
`DiffuselyUITests` is never run on this machine; the UI is verified by building
both the iOS and macOS targets and launching the Mac app directly. Test runs use
`-parallel-testing-enabled NO`.
