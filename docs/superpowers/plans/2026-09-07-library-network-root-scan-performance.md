# Network-Mounted Library Root Performance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Library on a network-mounted folder usable — a first scan in seconds rather than minutes, and an ordinary launch that costs a directory listing rather than a full re-read of every sidecar.

**Architecture:** `scanContainer` becomes three phases: a serial classification pass over the directory listing (no I/O beyond the listing), a bounded-width **concurrent** read of the sidecars that actually need reading, and a serial assembly of `ScanResult`. A per-item fingerprint (sidecar modification date + byte size, both free from the listing) lets the middle phase skip sidecars that have not changed since the index last ingested them.

**Tech Stack:** Swift 6, GCD (`OperationQueue`) — deliberately **not** Swift concurrency for the blocking reads — SwiftData, XCTest + swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-07-library-network-root-scan-performance.md`

## Execution order (revised after Task 0's measurement)

**0 → 5 → 1 → 2 → 3 → 4.** Task numbering is left alone so briefs and commits stay traceable; only the
order changes.

Task 0 measured the real scan and found `fileExists` is **27.8%** of it (219 s of 788 s), not the ~1%
the pre-work benchmark implied — the benchmark's per-file numbers were 11-30x optimistic because they
were measured against a warm client cache. Task 5 removes that 219 s, is the smallest change in the
plan, and depends on nothing: `scanContainer` already builds the `urlsByName` map it needs. It runs
first.

Measured projection for the whole plan (as of the plan being written, before Task 2 ran): ~788 s
today → ~568 s after Task 5 → ~73 s after Task 2 → ~3 s for an unchanged launch after Task 4.

**Corrected after Task 2's real measurement.** The ~73 s projection assumed the warm-cache benchmark's
8-way concurrency win (6.28 ms/file serial → 0.75 ms/file at 8-way) would hold cold, on the real share.
It did not: Task 2 measured 562.88 s serial → 612.24 s at 8-way — concurrency made it slightly WORSE,
with per-worker cost rising to 489 ms/file (~61 ms effective, indistinguishable from the 69.06 ms/file
serial baseline). The concurrency was reverted in the branch's final fix wave; the phase split it was
built on was kept, since it is what makes Task 4's per-sidecar skip a small diff. Actual outcome after
Task 5 + Task 2 (revert): ~788 s → ~622 s, a 21% improvement, entirely from Task 5's `fileExists`
removal — not the ~73 s this section originally projected. Task 4's incremental skip is unaffected by
the revert and still delivers the ~3 s unchanged-launch figure below.

## Global Constraints

- **Blocking file I/O uses GCD, never Swift concurrency.** `scanQueue` exists to keep `Data(contentsOf:)` off the cooperative pool; this repo has a documented history of pool starvation presenting as a grey spinner. `async let` / `TaskGroup` around these reads would reintroduce it at 8× the width.
- **"Not read" must never reach the pruning path.** Any indexed id absent from `seenIDs` is deleted. Every skipped or unreadable sidecar's id MUST still be inserted into `seenIDs`.
- **`ScanResult.items` ordering must stay deterministic** — never dependent on completion order.
- **Each concurrent operation gets its own `NSFileCoordinator`.** Sharing one across threads serializes them and the parallelization measures no faster.
- Concurrency width is one named constant, default **8**.
- `rebuild(itemsDirectory:)` must remain a **full**, non-incremental scan — "Rebuild Index" means "distrust the index".
- iOS must keep building; both test harnesses must stay green.
- Known-environmental: `LibraryTempMediaTests` EPERM pair, reported by XCTest as "2 failures (1 unexpected)". Exactly those two and nothing else is GREEN.

**Test commands:**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

## File Structure

| File | Change |
|---|---|
| `Diffusely/Services/Library/LibraryIndexService.swift` | Scan instrumentation, three-phase scan, concurrent reads, fingerprint skip, status-only updates |
| `Diffusely/Models/Persistence/PersistedLibraryItem.swift` | Three additive fingerprint fields |
| `DiffuselyTests/LibraryScanConcurrencyTests.swift` | New — parity between serial and concurrent scans |
| `DiffuselyTests/LibraryIncrementalReconcileTests.swift` | New — the prune-safety rule and skip behaviour |

No new production types. No `#if os(...)`: this is platform-neutral.

---

### Task 0: Instrument the real scan

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (`scanContainer`)
- Test: none — the deliverable is a measurement, not a behaviour

**Interfaces:**
- Consumes: nothing.
- Produces: a `ScanMetrics` struct printed once per scan; no change to `ScanResult` or any caller.

The benchmark in the spec predicts ~51 s for a scan observed to take 12+ minutes. **Nothing else in this plan should be trusted until that gap is explained**, because if the real bottleneck is decode cost in a debug build then Tasks 1–4 are correct but much less valuable.

- [ ] **Step 1: Add the metrics type and collect it**

In `LibraryIndexService`, above `scanContainer`:

```swift
    /// One scan's I/O profile. Printed once per scan so a slow container can be
    /// diagnosed from the log without a profiler attached — the numbers that
    /// motivated this work came from a synthetic benchmark that disagreed with
    /// observed behaviour by more than 10x, and this is how that gets settled.
    struct ScanMetrics {
        var listingSeconds = 0.0
        var sidecarsRead = 0
        var readSeconds = 0.0
        var decodeSeconds = 0.0
        var statCount = 0
        var statSeconds = 0.0

        var description: String {
            String(
                format: "[LibraryIndex] scan: listing %.2fs | %d sidecars read in %.2fs (%.2f ms each) | decode %.2fs | %d stats in %.2fs",
                listingSeconds, sidecarsRead, readSeconds,
                sidecarsRead > 0 ? readSeconds * 1000 / Double(sidecarsRead) : 0,
                decodeSeconds, statCount, statSeconds
            )
        }
    }
```

Time the four regions inside `scanContainer`: the `contentsOfDirectory` call, each `store.readMetadata`, each `decode`, and each `downloadStatus` call. Accumulate into a local `ScanMetrics` and emit it immediately before returning the result.

**Emit on stderr, not via `print`.** This was established the hard way: `print()` writes to stdout,
which is BLOCK-buffered when it is not a terminal, so a GUI app's sparse output never reaches a
captured log — a 25-second run captured 0 bytes. `stderr` is unbuffered, so use:

```swift
        FileHandle.standardError.write(Data((metrics.description + "\n").utf8))
```

Capture it by launching the app bundle with stderr redirected (verified working):

```bash
open -a <path to Diffusely.app> --stdout /tmp/scan.log --stderr /tmp/scan.log
```

Do NOT run the binary directly (`<app>/Contents/MacOS/Diffusely`) — it exits without running. Use `CFAbsoluteTimeGetCurrent()` rather than `Date()` for the per-file timers — at millisecond granularity across thousands of calls, `Date()`'s allocation shows up in what you are trying to measure.

- [ ] **Step 2: Build and confirm the line appears**

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | tail -3
```

Launch the app, let a scan run, and capture the printed line.

- [ ] **Step 3: Measure a DEBUG build against the real share**

Point the app at the network root and record the metrics line. Note the wall-clock time of the whole scan for comparison.

- [ ] **Step 4: Measure a RELEASE build against the same share**

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -configuration Release 2>&1 | tail -3
```

Run the release build the same way and record its metrics line.

**This step is the point of the task.** If release is dramatically faster than debug, decode cost was a large part of the 12 minutes and the plan's expected payoff changes — say so explicitly in the report rather than proceeding as if the benchmark held.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift
git commit -m "perf(library): instrument the container scan's I/O profile"
```

---

### Task 1: Split the scan into classify / read / assemble

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (`scanContainer`)
- Test: `DiffuselyTests/LibraryScanConcurrencyTests.swift` (create)

**Interfaces:**
- Consumes: Task 0's metrics.
- Produces: `scanContainer` restructured into three phases, still returning the same `ScanResult`. No signature change.

This task is a **pure refactor — no concurrency yet**. Splitting the phases while the behaviour is provably identical is what makes Task 2's concurrency a small, reviewable diff instead of a rewrite tangled with a behaviour change.

The existing loop mixes three concerns: album files, placeholder preservation, and item sidecar reads. Only the last is parallelizable. After this task:

- **Phase A (serial):** walk the sidecar URLs and classify each into an album, a preserved placeholder, or "needs reading" — using only values the listing already prefetched. All the `seenIDs` / `seenAlbumIDs` preservation logic stays here, untouched.
- **Phase B (serial for now):** read + decode each "needs reading" entry.
- **Phase C (serial):** assemble `ScanResult`.

- [ ] **Step 1: Write the parity test**

Create `DiffuselyTests/LibraryScanConcurrencyTests.swift`. It seeds a directory and asserts the scan's output, so it pins behaviour across both this refactor and Task 2's concurrency:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryScanConcurrencyTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seeds `count` complete items plus one album file, one unreadable sidecar
    /// and one foreign file, and returns the directory.
    private func seed(count: Int) throws -> URL {
        let dir = tempDir()
        for id in 1...count {
            let metadata = LibraryItemMetadata.fixture(itemID: id)
            try LibraryItemMetadata.encoder().encode(metadata)
                .write(to: dir.appendingPathComponent("\(id).json"))
            try Data("m".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(LibraryAlbumStore.fileName(for: UUID())))
        // Present but undecodable: must be counted as seen, never pruned.
        try Data("not json".utf8).write(to: dir.appendingPathComponent("999.json"))
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        return dir
    }

    @Test func scanFindsEveryItemAndPreservesTheUnreadableOne() throws {
        let dir = try seed(count: 25)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)

        let scan = try #require(LibraryIndexService.scanContainer(store: store))

        #expect(scan.items.count == 25)
        #expect(scan.seenIDs.count == 26, "the undecodable sidecar must still be seen, not pruned")
        #expect(scan.seenIDs.contains(999))
        #expect(scan.albums.count == 1)
    }

    /// Ordering must not depend on completion order once reads run concurrently.
    @Test func scanReturnsItemsInADeterministicOrder() throws {
        let dir = try seed(count: 40)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)

        let first = try #require(LibraryIndexService.scanContainer(store: store))
        let second = try #require(LibraryIndexService.scanContainer(store: store))

        #expect(first.items.map(\.metadata.itemID) == second.items.map(\.metadata.itemID))
    }
}
```

`LibraryItemMetadata.fixture(itemID:)` may not exist — check `DiffuselyTests` for the existing metadata builder (`makeMetadata` in `LibraryTests.swift`) and use whatever this suite already uses rather than adding a second fixture helper. If it is `private` to that file, promote it to a shared test helper instead of duplicating it.

- [ ] **Step 2: Run it — it must pass BEFORE the refactor**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryScanConcurrencyTests 2>&1 | tail -20
```

Expected: PASS. This is a characterization test — it pins today's behaviour so the refactor cannot change it. If it fails, the test is wrong about current behaviour; fix the test, not the production code.

- [ ] **Step 3: Extract the classification phase**

Introduce a work-item type above `scanContainer`:

```swift
    /// One sidecar the scan has classified but not yet read. Splitting
    /// classification from reading is what lets the reads run concurrently
    /// while every `seenIDs` preservation decision stays serial and in one place.
    private struct SidecarWork {
        let url: URL
        let mediaLookup: [String: URL]
        /// Recovered without reading, so an unreadable file can still be
        /// preserved rather than pruned.
        let preservedID: Int?
    }
```

Restructure `scanContainer` so the existing `for sidecarURL in sidecarURLs` loop does classification only: album branch unchanged, placeholder branch unchanged, and the item-sidecar branch appends a `SidecarWork` instead of reading. Then a second serial loop performs the read + decode + status exactly as today and appends to `items`.

Do not change any preservation rule, any counter, or the album handling.

- [ ] **Step 4: Verify the parity test still passes, plus the whole suite**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryScanConcurrencyTests.swift
git commit -m "refactor(library): split the container scan into classify and read phases"
```

---

### Task 2: Read sidecars concurrently

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift`
- Test: `DiffuselyTests/LibraryScanConcurrencyTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `SidecarWork` phase split.
- Produces: `nonisolated static let scanConcurrencyWidth = 8`; the read phase runs on a bounded `OperationQueue`.

Measured payoff on the real share: 6.28 ms/file serial → 0.75 ms/file at 8-way, i.e. ~51 s → ~6 s for 8,151 sidecars.

- [ ] **Step 1: Write the failing test**

Append to `LibraryScanConcurrencyTests`:

```swift
    /// The concurrent read phase must produce exactly what the serial one did.
    /// A fresh coordinator per operation is what makes this both correct and
    /// actually parallel; sharing one serialises the reads.
    @Test func concurrentScanMatchesSerialScanExactly() throws {
        let dir = try seed(count: 120)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)

        let serial = try #require(LibraryIndexService.scanContainer(store: store, concurrencyWidth: 1))
        let concurrent = try #require(LibraryIndexService.scanContainer(store: store, concurrencyWidth: 8))

        #expect(concurrent.items.map(\.metadata.itemID) == serial.items.map(\.metadata.itemID))
        #expect(concurrent.items.map(\.status) == serial.items.map(\.status))
        #expect(concurrent.seenIDs == serial.seenIDs)
        #expect(concurrent.seenAlbumIDs == serial.seenAlbumIDs)
        #expect(concurrent.pendingItems == serial.pendingItems)
    }
```

- [ ] **Step 2: Run it and watch it fail**

Expected: compile failure — `scanContainer` has no `concurrencyWidth` parameter.

- [ ] **Step 3: Implement the bounded concurrent read**

Add the constant and the parameter (defaulted, so no call site changes):

```swift
    /// How many sidecar reads run at once. Each is a blocking round trip, so on
    /// a network-mounted root the scan is latency-bound and width is close to a
    /// linear speedup: measured 6.28 ms/file serial vs 0.75 ms/file at 8-way
    /// over SMB. Bounded because this is also the cap on how many threads one
    /// scan may occupy.
    nonisolated static let scanConcurrencyWidth = 8
```

Replace the serial read loop with:

Task 0's `ScanMetrics` and the results array both become **shared mutable state** the instant reads
run concurrently. A captured `var` will not survive Swift 6's concurrency checking anyway, so both live
behind one small lock-guarded reference type:

```swift
    /// Collects concurrent read results and their timings behind one lock.
    /// A reference type because Swift 6 will not let a `@Sendable` operation
    /// closure capture and mutate a local `var`, and because Task 0's metrics
    /// counters are now written from every worker.
    private final class ScanAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var results: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)?]
        private(set) var metrics = ScanMetrics()

        init(count: Int) { results = Array(repeating: nil, count: count) }

        func record(index: Int,
                    result: (metadata: LibraryItemMetadata, status: LibraryDownloadStatus)?,
                    readSeconds: Double,
                    decodeSeconds: Double) {
            lock.lock()
            defer { lock.unlock() }
            results[index] = result
            metrics.sidecarsRead += 1
            metrics.readSeconds += readSeconds
            metrics.decodeSeconds += decodeSeconds
        }
    }
```

Note the metrics now measure *summed worker time*, not wall clock — at width 8 the sum will exceed the
scan's real duration. Say so in the printed line (or record wall clock separately), or Task 2's
"before/after" comparison will look like it made things worse.

```swift
        // Results are placed by INDEX, never appended, so `items` ordering
        // cannot depend on completion order. `OperationQueue` (not a TaskGroup)
        // because these reads block — running them on the cooperative pool is
        // the documented grey-spinner starvation bug.
        let accumulator = ScanAccumulator(count: work.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, concurrencyWidth)
        for (index, item) in work.enumerated() {
            queue.addOperation {
                guard
                    let id = store.itemID(forMetadataFile: item.url),
                    let data = store.readMetadata(itemID: id),
                    let metadata = try? LibraryItemMetadata.decoder()
                        .decode(LibraryItemMetadata.self, from: data)
                else { return }

                let mediaURL = store.mediaURL(itemID: metadata.itemID,
                                              plaintextExtension: metadata.mediaType.fileExtension)
                let lookupURL = item.mediaLookup[mediaURL.lastPathComponent] ?? mediaURL
                let status = downloadStatus(for: lookupURL, fileManager: FileManager.default)

                accumulator.record(index: index, result: (metadata: metadata, status: status),
                                   readSeconds: readElapsed, decodeSeconds: decodeElapsed)
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        for (index, result) in accumulator.results.enumerated() {
            guard let result else {
                // Unreadable or undecodable THIS round: present, so preserve the
                // row rather than pruning it. Same rule as the serial version.
                if let id = work[index].preservedID { seenIDs.insert(id) }
                continue
            }
            seenIDs.insert(result.metadata.itemID)
            items.append(result)
        }
```

`FileManager.default` is documented as thread-safe for these operations. `LibraryFileStore.read`
already constructs its own `NSFileCoordinator` per call (verified: `LibraryFileStore.swift:238`), so the
reads will not serialize on a shared coordinator — no change needed there, but re-confirm it still holds
before relying on it.

The `guard ... else { return }` inside the operation must ALSO record a nil result through the
accumulator, or an unreadable sidecar leaves its slot untouched and the preservation loop below cannot
tell "not read yet" from "read and failed". Record `nil` explicitly on that path.

- [ ] **Step 4: Verify the test passes and the suite is green**

Run the suite command from Global Constraints.

- [ ] **Step 5: Re-measure against the share and record the improvement**

Run the app against the network root and capture Task 0's metrics line. Record before/after in the report. If the improvement is far from the predicted ~8x, say so — that is a finding, not a formality.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryScanConcurrencyTests.swift
git commit -m "perf(library): read container sidecars concurrently"
```

---

### Task 3: Record a fingerprint for every ingested sidecar

**Files:**
- Modify: `Diffusely/Models/Persistence/PersistedLibraryItem.swift`
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift`
- Test: `DiffuselyTests/LibraryIncrementalReconcileTests.swift` (create)

**Interfaces:**
- Produces: `sidecarFileName: String`, `sidecarModifiedAt: Date?`, `sidecarByteSize: Int` on `PersistedLibraryItem`, populated on every ingest.

**No behaviour change in this task** — it only starts recording. Task 4 consumes it. Splitting them means the risky skip logic arrives as a small diff over a store that already has trustworthy fingerprints.

All three fields are additive with defaults, matching `needsDateBackfill` / `albumIDsJoined`. No migration plan is needed: `DiffuselyApp` implements "Rebuild, don't migrate" — a `ModelContainer` that fails to open destroys and recreates the store, and this index is disposable by design. Existing rows load with empty fingerprints, which read as "unknown, so read it".

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryIncrementalReconcileTests.swift` with a test that a reconcile records the fingerprint of the file it ingested — the row's `sidecarModifiedAt` and `sidecarByteSize` must match the file on disk, and `sidecarFileName` must be the name the scan actually saw.

- [ ] **Step 2: Run it and watch it fail** (no such properties)

- [ ] **Step 3: Add the fields**

```swift
    /// The sidecar this row was last ingested from, and its fingerprint at that
    /// moment. A later scan compares the two against the directory listing to
    /// decide whether the file needs re-reading at all.
    ///
    /// The NAME is stored rather than derived because an encrypted sidecar's
    /// filename is an opaque HMAC token carrying no item id — without this,
    /// incremental reconcile could only ever work for plaintext roots.
    /// Defaults are the "unknown, so read it" state, which is what every row
    /// written before this field existed will have.
    var sidecarFileName: String = ""
    var sidecarModifiedAt: Date?
    var sidecarByteSize: Int = 0
```

Add them to the convenience initializer with the same defaults.

- [ ] **Step 4: Carry the fingerprint through the scan**

Add `.contentModificationDateKey` and `.fileSizeKey` to `scanPrefetchKeys` — the listing already fetches resource values, so this costs nothing measurable. Add the fingerprint to `SidecarWork`, carry it into `ScanResult.items`, and write it in `apply(_:downloadStatus:to:)` and the `PersistedLibraryItem` initializer.

- [ ] **Step 5: Verify the test passes and the suite is green**

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Models/Persistence/PersistedLibraryItem.swift Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryIncrementalReconcileTests.swift
git commit -m "feat(library): record each item's sidecar fingerprint"
```

---

### Task 4: Skip unchanged sidecars

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift`
- Test: `DiffuselyTests/LibraryIncrementalReconcileTests.swift` (extend)

**Interfaces:**
- Consumes: Task 3's fingerprints.
- Produces: `reconcile` accepts a fingerprint map; `ScanResult` gains `statusUpdates: [(itemID: Int, status: LibraryDownloadStatus)]`.

**This is the highest-risk change in the plan.** Every index-pruning incident in this codebase came from treating "not seen" as "deleted", and this task deliberately makes more sidecars unread.

Two rules govern it:

1. **A skipped sidecar's id MUST be inserted into `seenIDs`.** Getting this wrong prunes the entire unchanged Library on the first incremental reconcile.
2. **A fingerprint covers the SIDECAR, not the media.** Skipping the read must still refresh download status, or an iCloud item whose media was evicted since the last scan would keep a stale "downloaded" badge forever. That is what `statusUpdates` is for: status is free from the listing, so compute it for skipped items too and apply it to the existing row without touching its metadata.

- [ ] **Step 1: Write the prune-safety test FIRST**

This is the test the task exists to satisfy:

```swift
    /// The rule this whole task lives or dies by: a sidecar that is skipped
    /// because it has not changed is still PRESENT, so its row must survive.
    /// If skipped ids stop reaching `seenIDs`, reconcile prunes the entire
    /// unchanged Library — the exact failure the eviction-sweep guards exist
    /// to prevent.
    @Test func unchangedSidecarsAreSkippedButTheirRowsSurvive() async throws {
        // seed 30 items, reconcile once to populate fingerprints,
        // then reconcile again with nothing changed
        // #expect(index.itemCount() == 30)
        // #expect(secondScan.sidecarsRead == 0)
    }
```

Flesh it out against the harness the suite already uses (`makeContainer()` / `LibraryIndexService(modelContainer:)`). Assert BOTH that the rows survive AND that no sidecar was read — surviving rows alone would also pass against an implementation that skipped nothing.

Add alongside it: a changed fingerprint forces a re-read; a new file is ingested; a deleted file IS pruned; and `rebuild(itemsDirectory:)` ignores fingerprints entirely.

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement the skip**

In `reconcile`, read the index's fingerprints on the model actor before the scan (`[String: (modifiedAt: Date?, size: Int, itemID: Int)]` keyed by sidecar filename) and pass them into `scanContainer`. In the classification phase, when a sidecar's name is in the map and both its modification date and size match the listing's values:

```swift
                // Unchanged since we last ingested it. Skip the READ, but the
                // file is present, so the id must still be seen or reconcile
                // prunes the row. Status is free from the listing, so refresh
                // it anyway: the fingerprint covers the sidecar, not the media,
                // and an evicted media file must still update the badge.
                seenIDs.insert(known.itemID)
                statusUpdates.append((itemID: known.itemID, status: status))
                continue
```

Apply `statusUpdates` in the apply path by fetching each row and setting only its download status.

`rebuild(itemsDirectory:)` passes an empty fingerprint map, so it always re-reads everything.

- [ ] **Step 4: Verify the tests pass and the suite is green**

- [ ] **Step 5: Measure a second launch against the share**

The payoff: a launch that changes nothing should now cost roughly the 2.24 s listing rather than a full scan. Capture Task 0's metrics line with `sidecarsRead` at or near zero, and record it in the report.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryIncrementalReconcileTests.swift
git commit -m "perf(library): skip re-reading sidecars that have not changed"
```

---

### Task 5: Drop the per-item `fileExists`

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (`downloadStatus`)
- Test: `DiffuselyTests/LibraryScanConcurrencyTests.swift` (extend)

**Interfaces:**
- Produces: `downloadStatus(for:fileManager:presentNames:)` — presence resolved from the listing when available. The new parameter MUST be defaulted (`presentNames: Set<String>? = nil`), because Task 2's concurrent read calls this function and every other caller passes no listing; an undefaulted parameter breaks them all.

**Measured at 26.91 ms/file, 219.36 s across 8,151 items — 27.8% of the entire scan.** The pre-work
benchmark said 0.91 ms and 7.4 s; it was measured against a warm cache and was 30x optimistic. This is
why the task runs first rather than last.

The cost has a specific cause worth understanding before changing it: the directory listing prefetches
resource values onto its URL objects, but `fileExists(atPath:)` bypasses that cache entirely and issues
a fresh metadata round trip per file. Resolving presence from the listing does not parallelize that
cost — it removes it.

- [ ] **Step 1: Write the failing test**

Assert that `downloadStatus` resolves an item's media as present using a supplied set of names **without touching the filesystem**, and still returns `.evicted` for a media file absent from that set. Then assert parity: a scan over a seeded directory produces identical statuses with and without the shortcut.

- [ ] **Step 2: Run it and watch it fail**

- [ ] **Step 3: Implement**

Give `downloadStatus` an optional set of names present in the listing. When supplied, use membership instead of `fileExists`; keep the existing ubiquity-status logic unchanged for iCloud roots, since that is where it is load-bearing. `scanContainer` already builds `urlsByName` — pass its keys.

Leave the `fileExists` path in place for callers that have no listing.

- [ ] **Step 4: Verify tests and suite green**

Do NOT attempt to re-measure against the share. That requires launching the app and waiting ~10 minutes,
and a subagent ends its turn when it waits — two dispatches were lost to exactly that. The controller
owns the measurement runs.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryScanConcurrencyTests.swift
git commit -m "perf(library): resolve media presence from the directory listing"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| Part 0 — instrument before optimizing | 0 |
| Part 1 — concurrent sidecar reads (GCD, bounded, own coordinator, deterministic order) | 1 (split), 2 (concurrency) |
| Part 2 — incremental reconcile, fingerprint = mtime + size from the listing | 3 (record), 4 (skip) |
| Fingerprint stored as filename + mtime + size; works for encrypted roots | 3 |
| `seenIDs` must include skipped ids | 4, with the dedicated test |
| `rebuild` stays a full scan | 4 |
| Part 3 — drop the per-item `fileExists` | 5 |
| Rejected: skip coordination, throttle the root re-check | absent by design |

**Placeholders:** Task 4 Step 1's test body is a sketch rather than complete code — deliberately, because it must be written against the existing `makeContainer()` harness, and inventing a second harness here would be worse than pointing at the real one. Every other code step is complete.

**Type consistency:** `SidecarWork` (Task 1) gains a fingerprint in Task 3 and is consumed in Task 4. `scanConcurrencyWidth` is named identically in Task 2's constant, parameter and tests. `ScanResult` grows `statusUpdates` only in Task 4.

**A resolved ambiguity the spec left open:** a fingerprint covers the sidecar, not the media, so skipping a read would strand download status. Task 4 handles it with `statusUpdates` rather than letting iCloud badges go stale — worth flagging because it is the kind of gap that only shows up on the encrypted root, months later.
