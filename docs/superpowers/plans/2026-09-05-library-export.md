# Library Export (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS-only "Export Library…" command that writes a complete, decrypted, resumable archive of the personal Library — media plus sidecars plus album files — into a user-chosen folder.

**Architecture:** A synchronous, nonisolated engine (`LibraryExporter`) does all the work against a `LibraryFileStore` and a destination `URL`, knowing nothing about vaults, SwiftData or SwiftUI. A `@MainActor ObservableObject` coordinator (`LibraryExportService`) resolves the vault once, dispatches the engine onto a dedicated serial queue, publishes throttled progress and owns cancellation. A File-menu command plus an `NSOpenPanel` and a progress sheet drive it.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit (`NSOpenPanel`, `NSWorkspace`), CryptoKit (`SHA256`), SwiftData (read-only, for sizing), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-05-library-export-design.md`

## Global Constraints

- **macOS only.** Every new UI file is wrapped entirely in `#if os(macOS)` / `#endif`, following `Diffusely/Views/QuickLookHost.swift`. The engine, planner and types are cross-platform (they must still compile on iOS) but are only *invoked* from macOS.
- **Xcode project needs no edits.** The project uses file-system synchronized root groups (`objectVersion = 77`), so files created under `Diffusely/` and `DiffuselyTests/` join their targets automatically. Never hand-edit `project.pbxproj`.
- **Never block the cooperative pool.** All coordinated I/O, iCloud waits and AES-GCM opens run on a dedicated `DispatchQueue`. `Task.detached` does NOT satisfy this — it still uses the cooperative pool. See the "grey-spinner cooperative-pool-starvation" bug class.
- **Queue label convention:** `com.achatessoftware.diffusely.library.<purpose>`.
- **Media extensions are `"jpeg"` / `"mp4"` only**, from `LibraryMediaType.fileExtension`. Never sniff content to rename; the archive is container-faithful.
- **SHA-256 is lowercase hex**, produced by `hasher.finalize().map { String(format: "%02x", $0) }.joined()` — matches `LibrarySaveService.sha256Hex(ofFileAt:)`.
- **Failures file name:** `_DiffuselyExport-failures.txt`, written in the destination root.
- **Partial file name:** `.<finalName>.partial`, in the destination root.
- **Prefetch window:** `K = 16`.
- **Progress throttle interval:** 0.1 seconds.
- **Build commands:**
  - macOS: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
  - iOS: `xcodebuild -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- **Test command** (always pass `-parallel-testing-enabled NO`; parallel workers are flaky on this machine):
  `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/<SuiteName>`
- **Never run `DiffuselyUITests`** — it disrupts the live machine. UI verification is by building both platforms and launching the Mac app.
- **Commit after every task**, ending each commit message with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `Diffusely/Services/Library/Export/LibraryExportTypes.swift` | Value types: failures, summary, errors, destination validation. No I/O beyond the validation checks. |
| `Diffusely/Services/Library/Export/LibraryExportPlan.swift` | Pre-flight counting and sizing. Pure given its inputs. |
| `Diffusely/Services/Library/Export/LibraryExporter.swift` | The engine: enumerate, prepare, materialize, verify, write. |
| `Diffusely/Services/Library/Export/LibraryExportService.swift` | `@MainActor` coordinator: vault, queue, phase, cancel, throttle. |
| `Diffusely/Utilities/LibraryExportPanel.swift` | macOS-only `NSOpenPanel` wrapper. |
| `Diffusely/Views/LibraryExportSheet.swift` | macOS-only confirm → progress → summary sheet. |
| `DiffuselyTests/LibraryExportDestinationTests.swift` | Task 1 tests. |
| `DiffuselyTests/LibraryExportPlanTests.swift` | Task 2 tests. |
| `DiffuselyTests/LibraryExporterTests.swift` | Tasks 3–6 tests. |
| `DiffuselyTests/LibraryExportServiceTests.swift` | Task 7 tests. |

**Modify:**

| File | Change |
|---|---|
| `Diffusely/Services/Library/LibraryFileStore.swift` | Add `readMetadata(at:)` — read a sidecar by URL in either mode. |
| `Diffusely/Services/Library/LibraryIndexService.swift` | Add `exportSizingRows()`. |
| `Diffusely/DiffuselyApp.swift` | Add `ExportCommands`, register it in `.commands`. |
| `Diffusely/ContentView.swift` | Add `ExportLibraryKey` focused value. |
| `Diffusely/Views/LibraryView.swift` | Publish `.focusedSceneValue`, host the sheet. |

---

### Task 1: Export value types and destination validation

The vocabulary every later task uses, plus the one guard that has real logic in it: refusing a destination that overlaps the iCloud container.

**Files:**
- Create: `Diffusely/Services/Library/Export/LibraryExportTypes.swift`
- Test: `DiffuselyTests/LibraryExportDestinationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct LibraryExportFailure: Equatable` with `init(itemID: Int?, fileName: String, reason: Reason)` and `enum Reason: Equatable { case sidecarUnreadable, sidecarUndecodable, mediaMissing, downloadFailed(String), integrityMismatch, writeFailed(String) }`
  - `struct LibraryExportSummary: Equatable` with `var exported: Int`, `var skipped: Int`, `var albumsExported: Int`, `var bytesWritten: Int`, `var cancelled: Bool`, `var failures: [LibraryExportFailure]`, and `init()` giving zeros / empty
  - `enum LibraryExportError: LocalizedError, Equatable { case vaultLocked, destinationInsideContainer, destinationNotWritable(String), insufficientSpace(needed: Int, available: Int) }`
  - `enum LibraryExportDestination { static func validate(destination: URL, itemsDirectory: URL, fileManager: FileManager = .default) throws }`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryExportDestinationTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryExportDestinationTests: XCTestCase {
    private func makeDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAcceptsUnrelatedWritableFolder() throws {
        let items = try makeDir("Items")
        let destination = try makeDir("Backup")
        XCTAssertNoThrow(try LibraryExportDestination.validate(
            destination: destination, itemsDirectory: items))
    }

    func testRefusesTheItemsDirectoryItself() throws {
        let items = try makeDir("Items")
        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: items, itemsDirectory: items)) { error in
            XCTAssertEqual(error as? LibraryExportError, .destinationInsideContainer)
        }
    }

    func testRefusesASubfolderOfTheItemsDirectory() throws {
        let items = try makeDir("Items")
        let inside = items.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: inside, itemsDirectory: items)) { error in
            XCTAssertEqual(error as? LibraryExportError, .destinationInsideContainer)
        }
    }

    func testRefusesAnAncestorOfTheItemsDirectory() throws {
        let items = try makeDir("Items")
        let parent = items.deletingLastPathComponent()
        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: parent, itemsDirectory: items)) { error in
            XCTAssertEqual(error as? LibraryExportError, .destinationInsideContainer)
        }
    }

    /// "Items2" must not be treated as living inside "Items" — a naive
    /// hasPrefix on paths without a trailing separator would say it does.
    func testSiblingWithSharedPrefixIsAccepted() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let items = base.appendingPathComponent("Items", isDirectory: true)
        let sibling = base.appendingPathComponent("Items2", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        XCTAssertNoThrow(try LibraryExportDestination.validate(
            destination: sibling, itemsDirectory: items))
    }

    func testRefusesMissingDestination() throws {
        let items = try makeDir("Items")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: missing, itemsDirectory: items)) { error in
            guard case .destinationNotWritable = (error as? LibraryExportError) else {
                return XCTFail("expected destinationNotWritable, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportDestinationTests`
Expected: FAIL — compile error, `cannot find 'LibraryExportDestination' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Services/Library/Export/LibraryExportTypes.swift`:

```swift
import Foundation

/// One item (or one container file) that did not export cleanly. Collected and
/// reported; never fatal to the run — see `LibraryExporter`.
struct LibraryExportFailure: Equatable {
    enum Reason: Equatable {
        /// The sidecar could not be read or decrypted.
        case sidecarUnreadable
        /// The sidecar was read but is not a decodable `LibraryItemMetadata`.
        case sidecarUndecodable
        /// The media file is absent, or unreadable after materialization.
        case mediaMissing
        /// iCloud materialization errored or timed out.
        case downloadFailed(String)
        /// SHA-256 of the media bytes disagreed with the sidecar's
        /// `contentSHA256`. The file IS still exported — the container's copy
        /// may be the only other copy, so refusing to back it up would turn
        /// one suspect copy into one suspect copy and no backup.
        case integrityMismatch
        case writeFailed(String)
    }

    /// Nil when the sidecar couldn't be decoded far enough to learn the id.
    let itemID: Int?
    /// The container file name, so an unidentifiable failure is still traceable.
    let fileName: String
    let reason: Reason
}

/// Outcome of one export run.
struct LibraryExportSummary: Equatable {
    var exported = 0
    var skipped = 0
    var albumsExported = 0
    var bytesWritten = 0
    var cancelled = false
    var failures: [LibraryExportFailure] = []

    init() {}
}

/// Setup-level refusals. These abort before anything is written and are the
/// only errors that surface as a failed export; per-item problems become
/// `LibraryExportFailure` values instead.
enum LibraryExportError: LocalizedError, Equatable {
    case vaultLocked
    case destinationInsideContainer
    case destinationNotWritable(String)
    case insufficientSpace(needed: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "Unlock the Library before exporting."
        case .destinationInsideContainer:
            return "Choose a folder outside the Library's iCloud container. "
                 + "Exporting into it would make the app treat the export as new items."
        case .destinationNotWritable(let path):
            return "Can't write to \(path)."
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "This export needs about \(f.string(fromByteCount: Int64(needed))), "
                 + "but only \(f.string(fromByteCount: Int64(available))) is available."
        }
    }
}

enum LibraryExportDestination {
    /// Rejects a destination that overlaps the Library container in either
    /// direction, or that we can't write to.
    static func validate(
        destination: URL,
        itemsDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        if overlaps(destination, itemsDirectory) {
            throw LibraryExportError.destinationInsideContainer
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: destination.path) else {
            throw LibraryExportError.destinationNotWritable(destination.path)
        }
    }

    /// True when either path is the other, or contains the other. Compared on
    /// standardized paths with a trailing separator so `/x/Items2` is not read
    /// as living inside `/x/Items`.
    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let pathA = normalized(a)
        let pathB = normalized(b)
        return pathA == pathB || pathA.hasPrefix(pathB) || pathB.hasPrefix(pathA)
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportDestinationTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExportTypes.swift DiffuselyTests/LibraryExportDestinationTests.swift
git commit -m "$(cat <<'EOF'
feat(library): export value types and destination validation

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Pre-flight plan (counting, sizing, free space)

The numbers behind the confirmation dialog. Driven by the SwiftData index rather than a container walk, so the dialog appears immediately.

**Files:**
- Create: `Diffusely/Services/Library/Export/LibraryExportPlan.swift`
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (add `exportSizingRows()` next to `summary()`, around line 812)
- Test: `DiffuselyTests/LibraryExportPlanTests.swift`

**Interfaces:**
- Consumes: `LibraryExportError` (Task 1).
- Produces:
  - `struct LibraryExportSizingRow: Equatable, Sendable { let itemID: Int; let mediaFileName: String; let fileByteSize: Int; let isEvicted: Bool }`
  - `struct LibraryExportPlan: Equatable { let itemsToExport: Int; let alreadyExported: Int; let bytesToDownload: Int; let bytesToWrite: Int; let availableBytes: Int; var fitsOnDisk: Bool }`
  - `enum LibraryExportPlanner { static func plan(destination:rows:availableBytes:fileManager:) -> LibraryExportPlan; static func availableCapacity(at:) -> Int }`
  - `LibraryIndexService.exportSizingRows() -> [LibraryExportSizingRow]`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryExportPlanTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryExportPlanTests: XCTestCase {
    private func makeDestination() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ dir: URL, _ name: String) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func row(_ id: Int, bytes: Int, evicted: Bool, ext: String = "jpeg") -> LibraryExportSizingRow {
        LibraryExportSizingRow(itemID: id, mediaFileName: "\(id).\(ext)",
                               fileByteSize: bytes, isEvicted: evicted)
    }

    func testCountsEverythingWhenDestinationIsEmpty() throws {
        let destination = try makeDestination()
        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 100, evicted: true), row(2, bytes: 50, evicted: false)],
            availableBytes: 10_000)

        XCTAssertEqual(plan.itemsToExport, 2)
        XCTAssertEqual(plan.alreadyExported, 0)
        XCTAssertEqual(plan.bytesToDownload, 100)   // only the evicted one
        XCTAssertEqual(plan.bytesToWrite, 150)      // both
        XCTAssertTrue(plan.fitsOnDisk)
    }

    func testItemNeedsBothFilesPresentToCountAsExported() throws {
        let destination = try makeDestination()
        try touch(destination, "1.jpeg")
        try touch(destination, "1.json")
        try touch(destination, "2.jpeg")            // media only — not done

        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 100, evicted: true), row(2, bytes: 50, evicted: true)],
            availableBytes: 10_000)

        XCTAssertEqual(plan.alreadyExported, 1)
        XCTAssertEqual(plan.itemsToExport, 1)
        XCTAssertEqual(plan.bytesToDownload, 50)
        XCTAssertEqual(plan.bytesToWrite, 50)
    }

    func testVideoRowsUseTheirOwnExtension() throws {
        let destination = try makeDestination()
        try touch(destination, "7.mp4")
        try touch(destination, "7.json")

        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(7, bytes: 900, evicted: true, ext: "mp4")],
            availableBytes: 10_000)

        XCTAssertEqual(plan.alreadyExported, 1)
        XCTAssertEqual(plan.itemsToExport, 0)
        XCTAssertEqual(plan.bytesToWrite, 0)
    }

    func testDoesNotFitWhenBytesToWriteExceedAvailable() throws {
        let destination = try makeDestination()
        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 5_000, evicted: false)],
            availableBytes: 1_000)

        XCTAssertFalse(plan.fitsOnDisk)
        XCTAssertEqual(plan.bytesToWrite, 5_000)
        // Locally-present items still count against free space even though
        // nothing needs downloading.
        XCTAssertEqual(plan.bytesToDownload, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportPlanTests`
Expected: FAIL — `cannot find 'LibraryExportPlanner' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Services/Library/Export/LibraryExportPlan.swift`:

```swift
import Foundation

/// One index row reduced to just what sizing an export needs. Taken from the
/// SwiftData index rather than the container so the confirmation dialog can be
/// built without touching a single file — a full container walk over an
/// evicted library would mean thousands of iCloud round-trips before the user
/// has even agreed to the export.
struct LibraryExportSizingRow: Equatable, Sendable {
    let itemID: Int
    /// `"<id>.jpeg"` / `"<id>.mp4"`, exactly as it appears in the container.
    let mediaFileName: String
    let fileByteSize: Int
    /// True when the media is not currently materialized locally.
    let isEvicted: Bool
}

struct LibraryExportPlan: Equatable {
    let itemsToExport: Int
    let alreadyExported: Int
    /// Bytes that must come down from iCloud — the evicted subset.
    let bytesToDownload: Int
    /// Bytes that will land on the destination volume — ALL items still to
    /// export, materialized or not. This, not `bytesToDownload`, is what the
    /// free-space check compares against.
    let bytesToWrite: Int
    let availableBytes: Int

    var fitsOnDisk: Bool { bytesToWrite <= availableBytes }
}

enum LibraryExportPlanner {
    static func plan(
        destination: URL,
        rows: [LibraryExportSizingRow],
        availableBytes: Int,
        fileManager: FileManager = .default
    ) -> LibraryExportPlan {
        let existing = Set(
            (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? [])

        var itemsToExport = 0
        var alreadyExported = 0
        var bytesToDownload = 0
        var bytesToWrite = 0

        for row in rows {
            let done = existing.contains(row.mediaFileName)
                && existing.contains("\(row.itemID).json")
            if done {
                alreadyExported += 1
                continue
            }
            itemsToExport += 1
            bytesToWrite += row.fileByteSize
            if row.isEvicted { bytesToDownload += row.fileByteSize }
        }

        return LibraryExportPlan(
            itemsToExport: itemsToExport,
            alreadyExported: alreadyExported,
            bytesToDownload: bytesToDownload,
            bytesToWrite: bytesToWrite,
            availableBytes: availableBytes)
    }

    /// Free space on the destination's volume. Uses
    /// `volumeAvailableCapacityForImportantUsage`, the figure that accounts
    /// for purgeable space, and returns 0 when it can't be read so the caller
    /// fails closed rather than promising room it hasn't verified.
    static func availableCapacity(at url: URL) -> Int {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
```

- [ ] **Step 4: Add the index accessor**

In `Diffusely/Services/Library/LibraryIndexService.swift`, immediately after the `summary()` function (which ends around line 821 with `return IndexSummary(...)` followed by `}`), add:

```swift
    /// Flat sizing rows for the macOS Library export's pre-flight plan. Reads
    /// the whole table once, like `summary()` — the export is a rare,
    /// user-initiated operation, so a single full fetch is cheaper and simpler
    /// than a predicate-narrowed query.
    func exportSizingRows() -> [LibraryExportSizingRow] {
        let items = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        return items.map {
            LibraryExportSizingRow(
                itemID: $0.itemID,
                mediaFileName: $0.mediaFileName,
                fileByteSize: $0.fileByteSize,
                isEvicted: $0.downloadStatus != .downloaded)
        }
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportPlanTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExportPlan.swift Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryExportPlanTests.swift
git commit -m "$(cat <<'EOF'
feat(library): export pre-flight plan and index sizing rows

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The export engine — items

The core write path, with iCloud materialization injected so tests never touch the network. No prefetch window and no album handling yet; those are Tasks 5 and 4.

**Files:**
- Create: `Diffusely/Services/Library/Export/LibraryExporter.swift`
- Modify: `Diffusely/Services/Library/LibraryFileStore.swift` (add `readMetadata(at:)` beside `readAux(at:)`, around line 128)
- Test: `DiffuselyTests/LibraryExporterTests.swift`

**Interfaces:**
- Consumes: `LibraryExportSummary`, `LibraryExportFailure` (Task 1).
- Produces:
  - `LibraryFileStore.readMetadata(at url: URL) -> Data?`
  - `struct LibraryExporter` with stored properties `store: LibraryFileStore`, `destination: URL`, `materialize: (URL) -> Error?`, `startPrefetch: (URL) -> Void`, `shouldCancel: () -> Bool`, an `init(store:destination:materialize:startPrefetch:shouldCancel:)` defaulting the last three, and `func run(progress: (Int, Int) -> Void) -> LibraryExportSummary`
  - `static let prefetchWindow = 16`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryExporterTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryExporterTests: XCTestCase {

    // MARK: Fixtures

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A fully decodable v6 sidecar whose `contentSHA256` matches `media`.
    /// Mirrors `LibraryEncryptionMigratorTests.seedFullPlaintext`'s approach of
    /// writing the JSON literally, so the fixture doesn't depend on the
    /// encoder's field ordering.
    private func sidecarJSON(id: Int, media: Data, ext: String = "jpeg",
                             mediaType: String = "image",
                             sha: String? = nil) -> Data {
        let digest = sha ?? sha256Hex(media)
        let json = """
        {"schemaVersion":6,"itemID":\(id),"canonicalPageURL":"x",\
        "sourceDomain":"civitai.com","originalCDNURL":"x","mediaType":"\(mediaType)",\
        "mediaFileName":"\(id).\(ext)","fileByteSize":\(media.count),\
        "contentSHA256":"\(digest)","width":1,"height":1,"nsfwLevel":1,\
        "author":{},"albumIDs":[],"savedAt":"2026-01-01T00:00:00Z",\
        "savedByAppVersion":"t"}
        """
        return Data(json.utf8)
    }

    /// Seeds one item into `store`, returning the exact sidecar bytes written
    /// so a test can assert the export reproduces them verbatim.
    @discardableResult
    private func seed(_ store: LibraryFileStore, id: Int,
                      media: Data, ext: String = "jpeg",
                      mediaType: String = "image",
                      sha: String? = nil) throws -> Data {
        let sidecar = sidecarJSON(id: id, media: media, ext: ext,
                                  mediaType: mediaType, sha: sha)
        try store.writeMetadata(sidecar, itemID: id)
        try store.writeMedia(media, itemID: id, plaintextExtension: ext)
        return sidecar
    }

    private func plaintextStore(_ dir: URL) -> LibraryFileStore {
        LibraryFileStore(itemsDirectory: dir, crypto: nil)
    }

    private func encryptedStore(_ dir: URL) -> LibraryFileStore {
        LibraryFileStore(itemsDirectory: dir,
                         crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
    }

    private func names(in dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    private func data(_ dir: URL, _ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    /// The exporter with iCloud stubbed out: everything is already local.
    private func exporter(_ store: LibraryFileStore, _ destination: URL,
                          shouldCancel: @escaping () -> Bool = { false }) -> LibraryExporter {
        LibraryExporter(store: store, destination: destination,
                        materialize: { _ in nil },
                        startPrefetch: { _ in },
                        shouldCancel: shouldCancel)
    }

    // MARK: Tests

    func testExportsMediaAndSidecarFromPlaintextStore() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let media = Data("media-bytes-1".utf8)
        let sidecar = try seed(store, id: 1, media: media)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.failures, [])
        XCTAssertEqual(data(destination, "1.jpeg"), media)
        XCTAssertEqual(data(destination, "1.json"), sidecar)
    }

    func testEncryptedStoreProducesIdenticalOutputToPlaintext() throws {
        let media = Data("media-bytes-2".utf8)

        let plainContainer = try makeDir(), plainOut = try makeDir()
        let plain = plaintextStore(plainContainer)
        try seed(plain, id: 2, media: media)
        _ = exporter(plain, plainOut).run { _, _ in }

        let encContainer = try makeDir(), encOut = try makeDir()
        let enc = encryptedStore(encContainer)
        try seed(enc, id: 2, media: media)
        _ = exporter(enc, encOut).run { _, _ in }

        XCTAssertEqual(names(in: plainOut), names(in: encOut))
        XCTAssertEqual(data(plainOut, "2.jpeg"), data(encOut, "2.jpeg"))
        XCTAssertEqual(data(plainOut, "2.json"), data(encOut, "2.json"))
    }

    /// Fidelity guarantee: the sidecar is copied, never decoded and re-encoded,
    /// so fields the current struct doesn't know about survive the round trip.
    func testSidecarIsWrittenVerbatimIncludingUnknownFields() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = encryptedStore(container)
        let media = Data("m".utf8)
        var json = String(data: sidecarJSON(id: 3, media: media), encoding: .utf8)!
        json = String(json.dropLast()) + ",\"futureField\":\"keep-me\"}"
        let sidecar = Data(json.utf8)
        try store.writeMetadata(sidecar, itemID: 3)
        try store.writeMedia(media, itemID: 3, plaintextExtension: "jpeg")

        _ = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(data(destination, "3.json"), sidecar)
    }

    func testVideoItemKeepsMp4Extension() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let media = Data("vid".utf8)
        try seed(store, id: 4, media: media, ext: "mp4", mediaType: "video")

        _ = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(data(destination, "4.mp4"), media)
        XCTAssertTrue(names(in: destination).contains("4.json"))
    }

    func testRerunSkipsAlreadyExportedItems() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 5, media: Data("m5".utf8))

        _ = exporter(store, destination).run { _, _ in }
        let second = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(second.exported, 0)
        XCTAssertEqual(second.skipped, 1)
    }

    /// A killed run can leave `.1.jpeg.partial`. It must be swept, and the item
    /// re-exported, rather than mistaken for finished work.
    func testStalePartialIsSweptAndItemReexported() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let media = Data("m6".utf8)
        try seed(store, id: 6, media: media)
        try Data("truncated".utf8)
            .write(to: destination.appendingPathComponent(".6.jpeg.partial"))

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(data(destination, "6.jpeg"), media)
        XCTAssertFalse(names(in: destination).contains(".6.jpeg.partial"))
    }

    func testHashMismatchIsReportedButFileStillExported() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let media = Data("m7".utf8)
        try seed(store, id: 7, media: media, sha: String(repeating: "0", count: 64))

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(data(destination, "7.jpeg"), media)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.itemID, 7)
        XCTAssertEqual(summary.failures.first?.reason, .integrityMismatch)
    }

    func testMissingMediaIsReportedAndOtherItemsStillExport() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try store.writeMetadata(sidecarJSON(id: 8, media: Data("gone".utf8)), itemID: 8)
        try seed(store, id: 9, media: Data("m9".utf8))

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertTrue(names(in: destination).contains("9.jpeg"))
        XCTAssertEqual(summary.failures.map(\.itemID), [8])
        XCTAssertEqual(summary.failures.first?.reason, .mediaMissing)
    }

    func testUndecodableSidecarIsReportedWithoutItemID() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try store.writeMetadata(Data("not json".utf8), itemID: 10)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 0)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertNil(summary.failures.first?.itemID)
        XCTAssertEqual(summary.failures.first?.reason, .sidecarUndecodable)
    }

    func testProgressReportsEveryItemAgainstTheTotal() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 11...13 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        var ticks: [(Int, Int)] = []
        _ = exporter(store, destination).run { done, total in ticks.append((done, total)) }

        XCTAssertEqual(ticks.map(\.0), [1, 2, 3])
        XCTAssertEqual(Set(ticks.map(\.1)), [3])
    }

    func testDownloadFailureIsReported() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 14, media: Data("m14".utf8))

        let failing = LibraryExporter(
            store: store, destination: destination,
            materialize: { url in
                url.lastPathComponent.hasSuffix(".jpeg") ? URLError(.timedOut) : nil
            },
            startPrefetch: { _ in },
            shouldCancel: { false })
        let summary = failing.run { _, _ in }

        XCTAssertEqual(summary.exported, 0)
        XCTAssertEqual(summary.failures.count, 1)
        guard case .downloadFailed = summary.failures.first?.reason else {
            return XCTFail("expected downloadFailed, got \(String(describing: summary.failures.first?.reason))")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: FAIL — `cannot find 'LibraryExporter' in scope`.

- [ ] **Step 3: Add `readMetadata(at:)` to the file store**

In `Diffusely/Services/Library/LibraryFileStore.swift`, immediately after `readAux(at:)` (which ends around line 133 with `return read(url: url, token: token)` and its closing `}`), add:

```swift
    /// Reads and decrypts a metadata sidecar located by its on-disk URL (as
    /// returned by `enumerateMetadataFiles()`), in either mode: encrypted
    /// recovers the token from the filename stem exactly as
    /// `itemID(forMetadataFile:)` does, plaintext reads the file directly.
    /// This is how a caller holding only an enumerated URL gets the FULL
    /// sidecar bytes — `itemID(forMetadataFile:)` decodes only an `{ itemID }`
    /// stub, and `readMetadata(itemID:)` needs an id the caller doesn't have
    /// yet. Used by the Library export, which must copy sidecar bytes verbatim.
    func readMetadata(at url: URL) -> Data? {
        guard isEncrypted else { return read(url: url, token: nil) }
        return read(url: url, token: url.deletingPathExtension().lastPathComponent)
    }
```

- [ ] **Step 4: Write the exporter**

Create `Diffusely/Services/Library/Export/LibraryExporter.swift`:

```swift
import Foundation
import CryptoKit

/// Writes a complete, decrypted copy of the Library container into a
/// destination folder, in the app's own plaintext layout (`<id>.jpeg` /
/// `<id>.mp4` + `<id>.json`, plus `album-<uuid>.json`).
///
/// Synchronous and nonisolated by design: every step here blocks (coordinated
/// reads, iCloud waits, AES-GCM opens), so the whole run belongs on a
/// dedicated queue — `LibraryExportService` provides one. Never call it from
/// the cooperative pool; see the "grey-spinner cooperative-pool-starvation"
/// bug class.
///
/// Unlike `LibraryEncryptionMigrator`, which stops on the first failure
/// because it mutates the live Library, this is a pure reader and collects
/// failures instead: an archive that aborts at item 400 of 6,500 because one
/// file is unreachable is worse than useless.
struct LibraryExporter {
    /// How far ahead of the write cursor the read-ahead cursor runs, kicking
    /// iCloud downloads so they proceed in parallel instead of one at a time.
    static let prefetchWindow = 16

    let store: LibraryFileStore
    let destination: URL

    /// Blocks until `url` is local, returning nil on success or the failure.
    /// Injected so tests never touch iCloud.
    let materialize: (URL) -> Error?
    /// Fire-and-forget download kick for a file the write cursor hasn't
    /// reached yet.
    let startPrefetch: (URL) -> Void
    let shouldCancel: () -> Bool

    init(store: LibraryFileStore,
         destination: URL,
         materialize: @escaping (URL) -> Error? = LibraryExporter.blockingMaterialize,
         startPrefetch: @escaping (URL) -> Void = LibraryExporter.kickDownload,
         shouldCancel: @escaping () -> Bool = { false }) {
        self.store = store
        self.destination = destination
        self.materialize = materialize
        self.startPrefetch = startPrefetch
        self.shouldCancel = shouldCancel
    }

    // MARK: Pipeline records

    /// An item the read-ahead cursor has resolved, ready for the write cursor.
    private struct Prepared {
        let itemID: Int
        let plaintextExtension: String
        let mediaName: String
        let sidecarName: String
        /// Verbatim decrypted sidecar bytes — written unchanged.
        let sidecarBytes: Data
        let expectedSHA256: String
    }

    private enum Step {
        case ready(Prepared)
        case skip
        case failure(LibraryExportFailure)
    }

    // MARK: Run

    func run(progress: (Int, Int) -> Void) -> LibraryExportSummary {
        var summary = LibraryExportSummary()
        sweepPartials()

        // Sorted so progress advances in a stable, comprehensible order and
        // an interrupted run resumes over the same sequence.
        let sources = store.enumerateMetadataFiles()
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let total = sources.count
        let existing = destinationNames()

        var queue: [Step] = []
        var nextToPrepare = 0
        var done = 0

        while true {
            if shouldCancel() {
                summary.cancelled = true
                break
            }

            // Read-ahead cursor: top the queue back up to the window, kicking
            // an iCloud download for each newly prepared item's media.
            while queue.count < Self.prefetchWindow, nextToPrepare < sources.count {
                let step = prepare(sources[nextToPrepare], existing: existing)
                nextToPrepare += 1
                if case .ready(let item) = step {
                    startPrefetch(store.mediaURL(itemID: item.itemID,
                                                 plaintextExtension: item.plaintextExtension))
                }
                queue.append(step)
            }

            guard !queue.isEmpty else { break }

            // Write cursor: strictly one item at a time, in order.
            switch queue.removeFirst() {
            case .ready(let item):
                write(item, into: &summary)
            case .skip:
                summary.skipped += 1
            case .failure(let failure):
                summary.failures.append(failure)
            }
            done += 1
            progress(done, total)
        }

        return summary
    }

    // MARK: Read-ahead

    private func prepare(_ url: URL, existing: Set<String>) -> Step {
        let name = url.lastPathComponent

        if let error = materialize(url) {
            return .failure(LibraryExportFailure(
                itemID: nil, fileName: name,
                reason: .downloadFailed(error.localizedDescription)))
        }
        guard let bytes = store.readMetadata(at: url) else {
            return .failure(LibraryExportFailure(
                itemID: nil, fileName: name, reason: .sidecarUnreadable))
        }
        guard let metadata = try? LibraryItemMetadata.decoder()
            .decode(LibraryItemMetadata.self, from: bytes) else {
            return .failure(LibraryExportFailure(
                itemID: nil, fileName: name, reason: .sidecarUndecodable))
        }

        let ext = metadata.mediaType.fileExtension
        let mediaName = "\(metadata.itemID).\(ext)"
        let sidecarName = "\(metadata.itemID).json"
        if existing.contains(mediaName), existing.contains(sidecarName) {
            return .skip
        }

        return .ready(Prepared(
            itemID: metadata.itemID,
            plaintextExtension: ext,
            mediaName: mediaName,
            sidecarName: sidecarName,
            sidecarBytes: bytes,
            expectedSHA256: metadata.contentSHA256))
    }

    // MARK: Write

    private func write(_ item: Prepared, into summary: inout LibraryExportSummary) {
        let mediaURL = store.mediaURL(itemID: item.itemID,
                                      plaintextExtension: item.plaintextExtension)
        if let error = materialize(mediaURL) {
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName,
                reason: .downloadFailed(error.localizedDescription)))
            return
        }
        guard let media = store.readMedia(itemID: item.itemID,
                                          plaintextExtension: item.plaintextExtension) else {
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName, reason: .mediaMissing))
            return
        }

        // A mismatch is reported but does NOT stop the write: the container's
        // copy may be the only other copy, so refusing to back it up would
        // turn one suspect copy into one suspect copy and no backup.
        if hexDigest(of: media) != item.expectedSHA256 {
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName, reason: .integrityMismatch))
        }

        do {
            try writeAtomically(media, name: item.mediaName)
            try writeAtomically(item.sidecarBytes, name: item.sidecarName)
            summary.exported += 1
            summary.bytesWritten += media.count
        } catch {
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName,
                reason: .writeFailed(error.localizedDescription)))
        }
    }

    /// Writes via `.<name>.partial` then an atomic rename, so a killed run
    /// never leaves a truncated file under a real name. That is precisely what
    /// makes skip-if-exists trustworthy on the next run.
    private func writeAtomically(_ data: Data, name: String) throws {
        let final = destination.appendingPathComponent(name)
        let partial = destination.appendingPathComponent(".\(name).partial")
        let fileManager = FileManager.default
        try data.write(to: partial, options: .atomic)
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
        }
        try fileManager.moveItem(at: partial, to: final)
    }

    // MARK: Helpers

    private func destinationNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
    }

    private func sweepPartials() {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        for name in names where name.hasPrefix("."), name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: destination.appendingPathComponent(name))
        }
    }

    private func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Default iCloud bridges

    /// Box for carrying a result out of the bridged `Task` below. The
    /// semaphore establishes the ordering, so the unchecked conformance is
    /// safe: the write happens-before the signal, the read after the wait.
    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    /// Blocks the calling (dedicated) thread until `url` is materialized.
    /// Bridging async → blocking with a semaphore mirrors
    /// `LibraryEncryptionMigrator.materializeIfNeeded`, and is safe for the
    /// same reason: it only ever blocks the export thread, never a Swift
    /// concurrency cooperative-pool thread.
    static func blockingMaterialize(_ url: URL) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task {
            if await LibraryFileMaterializer.isReady(url: url) == false {
                do {
                    try await LibraryFileMaterializer.download(url: url)
                } catch {
                    box.error = error
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.error
    }

    /// Fire-and-forget: asks iCloud to start pulling a file the write cursor
    /// hasn't reached yet, and returns immediately.
    static func kickDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: PASS, 11 tests.

- [ ] **Step 6: Verify both platforms still build**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
Then: `xcodebuild -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED for both.

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExporter.swift Diffusely/Services/Library/LibraryFileStore.swift DiffuselyTests/LibraryExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(library): export engine for items and sidecars

Writes media plus verbatim sidecar bytes into the destination via
temp-then-rename. Failures are collected, never fatal; a hash mismatch is
reported but still exported.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Export album files

Album membership already rides along on the item sidecars. This adds the album *records* — name, description, AI profile — so the archive is complete.

**Files:**
- Modify: `Diffusely/Services/Library/Export/LibraryExporter.swift`
- Test: `DiffuselyTests/LibraryExporterTests.swift`

**Interfaces:**
- Consumes: `LibraryExporter.run(progress:)` (Task 3), `LibraryAlbumFile`, `LibraryAlbumStore.fileName(for:)`, `SortAssistantState`.
- Produces: `LibraryExportSummary.albumsExported` is now populated; no new public API.

- [ ] **Step 1: Write the failing test**

Append to `DiffuselyTests/LibraryExporterTests.swift`, inside the class:

```swift
    // MARK: Albums

    private func makeAlbum(_ name: String) -> LibraryAlbumFile {
        LibraryAlbumFile(id: UUID(), name: name,
                         createdAt: Date(timeIntervalSince1970: 0))
    }

    func testExportsAlbumFilesFromPlaintextStore() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let album = makeAlbum("Landscapes")
        try LibraryAlbumStore(store: store).write(album)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.albumsExported, 1)
        let name = LibraryAlbumStore.fileName(for: album.id)
        XCTAssertTrue(names(in: destination).contains(name))
        let decoded = try LibraryAlbumFile.decoder()
            .decode(LibraryAlbumFile.self, from: XCTUnwrap(data(destination, name)))
        XCTAssertEqual(decoded, album)
    }

    /// Encrypted aux files are opaque `.x` names shared with the sort-assistant
    /// state, so albums are recovered by decode-and-classify — the same
    /// approach `LibraryEncryptionMigrator.decryptAux` uses.
    func testExportsAlbumFilesFromEncryptedStoreAndSkipsSortAssistantState() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = encryptedStore(container)
        let album = makeAlbum("Portraits")
        try LibraryAlbumStore(store: store).write(album)
        try store.writeAux(Data("{\"reviewed\":[]}".utf8),
                           name: SortAssistantStateStore.fileName)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.albumsExported, 1)
        XCTAssertEqual(names(in: destination), [LibraryAlbumStore.fileName(for: album.id)])
    }

    func testRerunSkipsAlbumsAlreadyExported() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try LibraryAlbumStore(store: store).write(makeAlbum("Sketches"))

        _ = exporter(store, destination).run { _, _ in }
        let second = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(second.albumsExported, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: FAIL — the three new tests fail on `albumsExported` being 0 and the album file being absent.

- [ ] **Step 3: Write the implementation**

In `Diffusely/Services/Library/Export/LibraryExporter.swift`, inside `run(progress:)`, replace the final `return summary` with:

```swift
        if !summary.cancelled {
            exportAlbums(into: &summary)
        }

        return summary
```

Then add this section just before `// MARK: Helpers`:

```swift
    // MARK: Albums

    /// Album records (name, description, AI profile). Membership is NOT here —
    /// it lives on each item's sidecar, which the item pass already copied.
    ///
    /// Plaintext stores keep their literal `album-<uuid>.json` names, so they
    /// are enumerated by prefix. Encrypted stores share one opaque `.x`
    /// namespace between album files and the sort-assistant state, with no
    /// filename hint, so albums are recovered by decode-and-classify —
    /// the approach `LibraryEncryptionMigrator.decryptAux` established.
    private func exportAlbums(into summary: inout LibraryExportSummary) {
        let existing = destinationNames()
        for (name, payload) in albumPayloads() {
            guard !existing.contains(name) else { continue }
            do {
                try writeAtomically(payload, name: name)
                summary.albumsExported += 1
                summary.bytesWritten += payload.count
            } catch {
                summary.failures.append(LibraryExportFailure(
                    itemID: nil, fileName: name,
                    reason: .writeFailed(error.localizedDescription)))
            }
        }
    }

    /// `(destination file name, bytes)` for every album file in the container.
    private func albumPayloads() -> [(String, Data)] {
        if store.isEncrypted {
            return store.enumerateAuxFiles().compactMap { url in
                guard let payload = store.readAux(at: url),
                      let album = try? LibraryAlbumFile.decoder()
                        .decode(LibraryAlbumFile.self, from: payload) else { return nil }
                return (LibraryAlbumStore.fileName(for: album.id), payload)
            }
        }

        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: store.itemsDirectory.path)) ?? []
        return names.compactMap { name in
            guard LibraryAlbumStore.albumID(fromFileName: name) != nil,
                  let payload = store.readAux(name: name) else { return nil }
            return (name, payload)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExporter.swift DiffuselyTests/LibraryExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(library): export album files alongside items

Decode-and-classify recovers albums from the shared opaque aux namespace,
skipping sort-assistant state.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Cancellation and prefetch verification

Task 3 already wired `shouldCancel` and `startPrefetch` into the loop. This task pins their behavior down with tests, and makes the default materializer honour cancellation so Cancel doesn't wait out a 2-minute download timeout.

**Files:**
- Modify: `Diffusely/Services/Library/Export/LibraryExporter.swift`
- Test: `DiffuselyTests/LibraryExporterTests.swift`

**Interfaces:**
- Consumes: `LibraryExporter` (Task 3).
- Produces: `static func makeBlockingMaterializer(shouldCancel: @escaping () -> Bool) -> (URL) -> Error?`, replacing `blockingMaterialize` as the default.

- [ ] **Step 1: Write the failing test**

Append to `DiffuselyTests/LibraryExporterTests.swift`, inside the class:

```swift
    // MARK: Cancellation and prefetch

    func testCancellationStopsEarlyAndLeavesAResumableExport() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 20...25 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        var written = 0
        let cancelling = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in nil },
            startPrefetch: { _ in },
            shouldCancel: { written >= 2 })
        let summary = cancelling.run { done, _ in written = done }

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.exported, 2)

        // Whatever landed is complete and correct, and a re-run finishes the job.
        XCTAssertFalse(names(in: destination).contains { $0.hasSuffix(".partial") })
        let resumed = exporter(store, destination).run { _, _ in }
        XCTAssertEqual(resumed.skipped, 2)
        XCTAssertEqual(resumed.exported, 4)
    }

    func testCancelledRunDoesNotExportAlbums() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 30...32 { try seed(store, id: id, media: Data("m\(id)".utf8)) }
        try LibraryAlbumStore(store: store).write(makeAlbum("Later"))

        var written = 0
        let cancelling = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in nil },
            startPrefetch: { _ in },
            shouldCancel: { written >= 1 })
        let summary = cancelling.run { done, _ in written = done }

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.albumsExported, 0)
    }

    /// The read-ahead cursor must kick downloads for items the write cursor
    /// has not reached yet — that parallelism is the whole point of the window.
    func testPrefetchIsKickedAheadOfTheWriteCursor() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 40...45 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        var prefetched: [String] = []
        var prefetchedBeforeFirstWrite = 0
        var writes = 0

        let instrumented = LibraryExporter(
            store: store, destination: destination,
            materialize: { url in
                if url.lastPathComponent.hasSuffix(".jpeg") {
                    writes += 1
                    if writes == 1 { prefetchedBeforeFirstWrite = prefetched.count }
                }
                return nil
            },
            startPrefetch: { prefetched.append($0.lastPathComponent) },
            shouldCancel: { false })
        _ = instrumented.run { _, _ in }

        // All six items are inside the 16-item window, so every download is
        // kicked before the first media file is even opened.
        XCTAssertEqual(prefetchedBeforeFirstWrite, 6)
        XCTAssertEqual(Set(prefetched), Set((40...45).map { "\($0).jpeg" }))
    }

    func testAlreadyExportedItemsAreNotPrefetched() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 50, media: Data("m50".utf8))
        _ = exporter(store, destination).run { _, _ in }

        var prefetched: [String] = []
        let second = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in nil },
            startPrefetch: { prefetched.append($0.lastPathComponent) },
            shouldCancel: { false })
        _ = second.run { _, _ in }

        XCTAssertEqual(prefetched, [])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: `testCancelledRunDoesNotExportAlbums` may already pass (Task 4 guarded it); the others exercise behavior Task 3 wired but never verified. Note precisely which fail — if all four pass, the loop is already correct and only Step 3's cancellable materializer is new work.

- [ ] **Step 3: Make the default materializer cancellable**

In `Diffusely/Services/Library/Export/LibraryExporter.swift`, change the `init`'s default from `LibraryExporter.blockingMaterialize` so the materializer can see the same cancel flag. Replace the initializer's first two lines of signature:

```swift
    init(store: LibraryFileStore,
         destination: URL,
         materialize: ((URL) -> Error?)? = nil,
         startPrefetch: @escaping (URL) -> Void = LibraryExporter.kickDownload,
         shouldCancel: @escaping () -> Bool = { false }) {
        self.store = store
        self.destination = destination
        self.startPrefetch = startPrefetch
        self.shouldCancel = shouldCancel
        self.materialize = materialize
            ?? LibraryExporter.makeBlockingMaterializer(shouldCancel: shouldCancel)
    }
```

Then replace the whole `static func blockingMaterialize(_:)` with:

```swift
    /// Blocks the calling (dedicated) thread until `url` is materialized,
    /// polling the cancel flag while it waits so Cancel responds in a quarter
    /// of a second rather than after the materializer's 2-minute ceiling.
    ///
    /// Bridging async → blocking with a semaphore mirrors
    /// `LibraryEncryptionMigrator.materializeIfNeeded`, and is safe for the
    /// same reason: it only ever blocks the export thread, never a Swift
    /// concurrency cooperative-pool thread. Cancelling the bridged `Task` is
    /// what makes `LibraryFileMaterializer.download` throw `CancellationError`
    /// out of its poll loop.
    static func makeBlockingMaterializer(
        shouldCancel: @escaping () -> Bool
    ) -> (URL) -> Error? {
        { url in
            let semaphore = DispatchSemaphore(value: 0)
            let box = ErrorBox()
            let task = Task {
                if await LibraryFileMaterializer.isReady(url: url) == false {
                    do {
                        try await LibraryFileMaterializer.download(url: url)
                    } catch {
                        box.error = error
                    }
                }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
                if shouldCancel() { task.cancel() }
            }
            return box.error
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: PASS, 18 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExporter.swift DiffuselyTests/LibraryExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(library): cancellable export downloads, prefetch window coverage

Cancel now cuts an in-flight iCloud wait within ~0.25s instead of after the
materializer's 2-minute ceiling.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Failures file

A summary the user can still read after dismissing the sheet.

**Files:**
- Modify: `Diffusely/Services/Library/Export/LibraryExporter.swift`
- Test: `DiffuselyTests/LibraryExporterTests.swift`

**Interfaces:**
- Consumes: `LibraryExportSummary.failures` (Task 1), `LibraryExporter.run` (Task 3).
- Produces: `static let failuresFileName = "_DiffuselyExport-failures.txt"`.

- [ ] **Step 1: Write the failing test**

Append to `DiffuselyTests/LibraryExporterTests.swift`, inside the class:

```swift
    // MARK: Failures file

    func testFailuresFileIsWrittenWhenSomethingFails() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try store.writeMetadata(sidecarJSON(id: 60, media: Data("gone".utf8)), itemID: 60)

        _ = exporter(store, destination).run { _, _ in }

        let report = try XCTUnwrap(data(destination, LibraryExporter.failuresFileName))
        let text = try XCTUnwrap(String(data: report, encoding: .utf8))
        XCTAssertTrue(text.contains("60"), text)
        XCTAssertTrue(text.lowercased().contains("media"), text)
    }

    func testNoFailuresFileOnACleanRun() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 61, media: Data("m61".utf8))

        _ = exporter(store, destination).run { _, _ in }

        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
    }

    /// A stale report must not outlive the failures it describes.
    func testStaleFailuresFileIsRemovedByACleanRun() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 62, media: Data("m62".utf8))
        try Data("old news".utf8).write(
            to: destination.appendingPathComponent(LibraryExporter.failuresFileName))

        _ = exporter(store, destination).run { _, _ in }

        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: FAIL — `type 'LibraryExporter' has no member 'failuresFileName'`.

- [ ] **Step 3: Write the implementation**

In `Diffusely/Services/Library/Export/LibraryExporter.swift`, add beside `prefetchWindow`:

```swift
    /// Written in the destination root, and ONLY when something failed. It
    /// describes the most recent run alone: any existing copy is removed at
    /// the start of a run, so a clean re-run never leaves a stale report
    /// claiming failures that have since been resolved. Deliberately not
    /// `.json` — the folder is meant to stay usable as a Library later, and
    /// the app enumerates `*.json` there.
    static let failuresFileName = "_DiffuselyExport-failures.txt"
```

In `run(progress:)`, add the stale-report removal immediately after `sweepPartials()`:

```swift
        removeFailuresFile()
```

and write the report just before the final `return summary`:

```swift
        if !summary.failures.isEmpty {
            writeFailuresFile(summary.failures)
        }
```

Then add, next to `sweepPartials()`:

```swift
    private var failuresFileURL: URL {
        destination.appendingPathComponent(Self.failuresFileName)
    }

    private func removeFailuresFile() {
        try? FileManager.default.removeItem(at: failuresFileURL)
    }

    private func writeFailuresFile(_ failures: [LibraryExportFailure]) {
        var lines = [
            "Diffusely library export — \(ISO8601DateFormatter().string(from: Date()))",
            "\(failures.count) item(s) did not export cleanly.",
            ""
        ]
        for failure in failures {
            let id = failure.itemID.map(String.init) ?? "unknown"
            lines.append("item \(id)  (\(failure.fileName))  — \(Self.describe(failure.reason))")
        }
        try? Data(lines.joined(separator: "\n").appending("\n").utf8)
            .write(to: failuresFileURL, options: .atomic)
    }

    private static func describe(_ reason: LibraryExportFailure.Reason) -> String {
        switch reason {
        case .sidecarUnreadable:
            return "sidecar could not be read or decrypted"
        case .sidecarUndecodable:
            return "sidecar is not valid item metadata"
        case .mediaMissing:
            return "media file missing or unreadable"
        case .downloadFailed(let message):
            return "iCloud download failed: \(message)"
        case .integrityMismatch:
            return "media does not match its recorded SHA-256 — EXPORTED ANYWAY, verify this file"
        case .writeFailed(let message):
            return "could not write to the destination: \(message)"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExporterTests`
Expected: PASS, 21 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExporter.swift DiffuselyTests/LibraryExporterTests.swift
git commit -m "$(cat <<'EOF'
feat(library): write an export failures report

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: The coordinator service

Everything the engine deliberately doesn't know: the vault, the queue, the published phase, progress throttling, keeping the Mac awake.

**Files:**
- Create: `Diffusely/Services/Library/Export/LibraryExportService.swift`
- Test: `DiffuselyTests/LibraryExportServiceTests.swift`

**Interfaces:**
- Consumes: `LibraryExporter` (Tasks 3–6), `LibraryExportPlanner`, `LibraryExportSizingRow` (Task 2), `LibraryExportDestination`, `LibraryExportError`, `LibraryExportSummary` (Task 1).
- Produces:
  - `struct ExportProgressCoalescer { init(interval: TimeInterval); mutating func shouldEmit(at now: Date, isFinal: Bool) -> Bool }`
  - `@MainActor final class LibraryExportService: ObservableObject` with `enum Phase: Equatable { case idle, preparing, confirming(LibraryExportPlan), exporting(done: Int, total: Int), finished(LibraryExportSummary), failed(String) }`, `@Published private(set) var phase: Phase`, `init(resolveContext:sizingRows:)`, `func prepare(destination: URL) async`, `func start()`, `func cancel()`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryExportServiceTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryExportServiceTests: XCTestCase {

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Progress coalescing

    func testCoalescerEmitsFirstTickImmediately() {
        var coalescer = ExportProgressCoalescer(interval: 0.1)
        XCTAssertTrue(coalescer.shouldEmit(at: Date(timeIntervalSince1970: 0), isFinal: false))
    }

    func testCoalescerSuppressesTicksInsideTheInterval() {
        var coalescer = ExportProgressCoalescer(interval: 0.1)
        let start = Date(timeIntervalSince1970: 0)
        _ = coalescer.shouldEmit(at: start, isFinal: false)
        XCTAssertFalse(coalescer.shouldEmit(at: start.addingTimeInterval(0.05), isFinal: false))
    }

    func testCoalescerEmitsAgainAfterTheInterval() {
        var coalescer = ExportProgressCoalescer(interval: 0.1)
        let start = Date(timeIntervalSince1970: 0)
        _ = coalescer.shouldEmit(at: start, isFinal: false)
        XCTAssertTrue(coalescer.shouldEmit(at: start.addingTimeInterval(0.2), isFinal: false))
    }

    /// The last tick must never be dropped — the bar has to reach 100%.
    func testCoalescerAlwaysEmitsTheFinalTick() {
        var coalescer = ExportProgressCoalescer(interval: 0.1)
        let start = Date(timeIntervalSince1970: 0)
        _ = coalescer.shouldEmit(at: start, isFinal: false)
        XCTAssertTrue(coalescer.shouldEmit(at: start.addingTimeInterval(0.01), isFinal: true))
    }

    // MARK: Service

    @MainActor
    func testPrepareFailsWhenTheVaultIsLocked() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        let service = LibraryExportService(
            resolveContext: { (.locked, store) },
            sizingRows: { [] })

        await service.prepare(destination: destination)

        guard case .failed(let message) = service.phase else {
            return XCTFail("expected .failed, got \(service.phase)")
        }
        XCTAssertEqual(message, LibraryExportError.vaultLocked.errorDescription)
    }

    @MainActor
    func testPrepareFailsWhenDestinationIsInsideTheContainer() async throws {
        let container = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        let service = LibraryExportService(
            resolveContext: { (.notConfigured, store) },
            sizingRows: { [] })

        await service.prepare(destination: container)

        guard case .failed(let message) = service.phase else {
            return XCTFail("expected .failed, got \(service.phase)")
        }
        XCTAssertEqual(message, LibraryExportError.destinationInsideContainer.errorDescription)
    }

    @MainActor
    func testPrepareProducesAConfirmablePlan() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        let rows = [LibraryExportSizingRow(itemID: 1, mediaFileName: "1.jpeg",
                                           fileByteSize: 10, isEvicted: true)]
        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { rows })

        await service.prepare(destination: destination)

        guard case .confirming(let plan) = service.phase else {
            return XCTFail("expected .confirming, got \(service.phase)")
        }
        XCTAssertEqual(plan.itemsToExport, 1)
        XCTAssertEqual(plan.bytesToDownload, 10)
    }

    @MainActor
    func testStartRunsTheExportAndFinishes() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        let media = Data("m".utf8)
        let sha = SHA256.hash(data: media).map { String(format: "%02x", $0) }.joined()
        let sidecar = Data("""
        {"schemaVersion":6,"itemID":1,"canonicalPageURL":"x","sourceDomain":"civitai.com",\
        "originalCDNURL":"x","mediaType":"image","mediaFileName":"1.jpeg","fileByteSize":1,\
        "contentSHA256":"\(sha)","width":1,"height":1,"nsfwLevel":1,"author":{},\
        "albumIDs":[],"savedAt":"2026-01-01T00:00:00Z","savedByAppVersion":"t"}
        """.utf8)
        try store.writeMetadata(sidecar, itemID: 1)
        try store.writeMedia(media, itemID: 1, plaintextExtension: "jpeg")

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })
        await service.prepare(destination: destination)
        service.start()

        // Poll rather than sleep-and-hope: the run is on a background queue.
        for _ in 0..<200 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        guard case .finished(let summary) = service.phase else {
            return XCTFail("expected .finished, got \(service.phase)")
        }
        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("1.jpeg")), media)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportServiceTests`
Expected: FAIL — `cannot find 'ExportProgressCoalescer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Diffusely/Services/Library/Export/LibraryExportService.swift`:

```swift
import Foundation
import SwiftUI

/// Rate-limits progress ticks. The engine reports every item; at 6,500 items a
/// main-actor hop each would be needless churn, so ticks are coalesced to one
/// per `interval` — with the final tick always allowed through so the bar
/// actually reaches 100%.
struct ExportProgressCoalescer {
    private let interval: TimeInterval
    private var lastEmit: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func shouldEmit(at now: Date, isFinal: Bool) -> Bool {
        if isFinal {
            lastEmit = now
            return true
        }
        if let lastEmit, now.timeIntervalSince(lastEmit) < interval {
            return false
        }
        lastEmit = now
        return true
    }
}

/// Drives one Library export: resolves the vault, validates the destination,
/// builds the plan, and runs `LibraryExporter` on a dedicated serial queue.
///
/// Follows `LibraryEncryptionCoordinator` (published `Phase`, dedicated
/// `ioQueue`) and `SortAssistantService` (`runTask` + `cancel()`). The vault is
/// reached through an injected closure, matching the `resolveVaultContext`
/// seam used by `SortAssistantScanner` and `LibraryAlbumService`, so tests
/// never touch the shared singleton.
@MainActor
final class LibraryExportService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case confirming(LibraryExportPlan)
        case exporting(done: Int, total: Int)
        case finished(LibraryExportSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Destination chosen in the open panel; retained for `start()` and for
    /// the sheet's "Reveal in Finder".
    private(set) var destination: URL?

    private let resolveContext: () async -> (LibraryVault.State, LibraryFileStore)
    private let sizingRows: () async -> [LibraryExportSizingRow]

    private var store: LibraryFileStore?
    private var runTask: Task<Void, Never>?
    /// Set on the main actor, read from the export queue and from inside the
    /// materializer's wait loop, so it needs real cross-thread safety — a
    /// main-actor `Bool` read via `MainActor.assumeIsolated` would trap when
    /// the export thread calls it.
    private var cancelFlag = CancelFlag()

    /// Minimal thread-safe latch for cooperative cancellation.
    final class CancelFlag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock(); value = true; lock.unlock()
        }
    }

    /// Dedicated serial queue for the export loop's blocking work: coordinated
    /// reads, iCloud materialization waits, AES-GCM opens, destination writes.
    /// Mirrors `LibraryEncryptionCoordinator.ioQueue`. Serial because progress
    /// ordering and the write cursor's one-at-a-time contract both depend on it.
    private static let exportQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.export",
        qos: .userInitiated
    )

    init(resolveContext: @escaping () async -> (LibraryVault.State, LibraryFileStore),
         sizingRows: @escaping () async -> [LibraryExportSizingRow]) {
        self.resolveContext = resolveContext
        self.sizingRows = sizingRows
    }

    /// Production wiring: the shared vault plus the live index.
    static func live(indexService: LibraryIndexService) -> LibraryExportService {
        LibraryExportService(
            resolveContext: { await LibraryVaultProvider.shared.reconcileContext() },
            sizingRows: { await indexService.exportSizingRows() })
    }

    // MARK: Pre-flight

    func prepare(destination: URL) async {
        phase = .preparing
        self.destination = destination

        // One resolve, up front: state and crypto must come from the same
        // snapshot or a lock landing between two reads could hand us a
        // passthrough store over an encrypted container.
        let (state, store) = await resolveContext()
        guard state != .locked else {
            return fail(.vaultLocked)
        }
        self.store = store

        do {
            try LibraryExportDestination.validate(
                destination: destination, itemsDirectory: store.itemsDirectory)
        } catch let error as LibraryExportError {
            return fail(error)
        } catch {
            return fail(.destinationNotWritable(destination.path))
        }

        let rows = await sizingRows()
        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: rows,
            availableBytes: LibraryExportPlanner.availableCapacity(at: destination))

        guard plan.fitsOnDisk else {
            return fail(.insufficientSpace(needed: plan.bytesToWrite,
                                           available: plan.availableBytes))
        }
        phase = .confirming(plan)
    }

    // MARK: Run

    func start() {
        guard case .confirming(let plan) = phase,
              let store, let destination else { return }

        cancelFlag = CancelFlag()
        let flag = cancelFlag
        phase = .exporting(done: 0, total: max(plan.itemsToExport, 1))

        runTask = Task { [weak self] in
            let summary = await Self.runExport(
                store: store,
                destination: destination,
                shouldCancel: { flag.isSet },
                onProgress: { done, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .exporting = self.phase else { return }
                        self.phase = .exporting(done: done, total: total)
                    }
                })
            guard let self else { return }
            self.phase = .finished(summary)
        }
    }

    func cancel() {
        cancelFlag.set()
    }

    // MARK: Queue bridge

    /// Runs the engine on `exportQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread. Mirrors
    /// `LibraryEncryptionCoordinator.runOnIOQueue`.
    private static func runExport(
        store: LibraryFileStore,
        destination: URL,
        shouldCancel: @escaping () -> Bool,
        onProgress: @escaping (Int, Int) -> Void
    ) async -> LibraryExportSummary {
        await withCheckedContinuation { continuation in
            exportQueue.async {
                // An export can run for hours. Keep the Mac from idle-sleeping
                // through it; closing the lid still suspends normally.
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated],
                    reason: "Exporting the Diffusely library")
                defer { ProcessInfo.processInfo.endActivity(activity) }

                var coalescer = ExportProgressCoalescer(interval: 0.1)
                let exporter = LibraryExporter(
                    store: store,
                    destination: destination,
                    shouldCancel: shouldCancel)
                let summary = exporter.run { done, total in
                    if coalescer.shouldEmit(at: Date(), isFinal: done == total) {
                        onProgress(done, total)
                    }
                }
                continuation.resume(returning: summary)
            }
        }
    }

    // MARK: Helpers

    private func fail(_ error: LibraryExportError) {
        phase = .failed(error.errorDescription ?? "Export failed.")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportServiceTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Verify both platforms still build**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
Then: `xcodebuild -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED for both.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/Export/LibraryExportService.swift DiffuselyTests/LibraryExportServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(library): export coordinator with plan, progress and cancellation

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: macOS entry point and progress sheet

The user-facing half: a File-menu command gated on a browsable Library, an `NSOpenPanel`, and the confirm → progress → summary sheet.

**Files:**
- Create: `Diffusely/Utilities/LibraryExportPanel.swift`
- Create: `Diffusely/Views/LibraryExportSheet.swift`
- Modify: `Diffusely/ContentView.swift` (add the focused-value key after `SidebarSelectionKey`, around line 37)
- Modify: `Diffusely/DiffuselyApp.swift` (add `ExportCommands` in the `#if os(macOS)` block, register in `.commands` around line 179)
- Modify: `Diffusely/Views/LibraryView.swift` (state, sheet, focused value)

**Interfaces:**
- Consumes: `LibraryExportService`, `LibraryExportService.Phase`, `LibraryExportPlan`, `LibraryExportSummary`, `LibraryExporter.failuresFileName`.
- Produces: `LibraryExportPanel.chooseDestination() -> URL?`; `FocusedValues.exportLibrary`; `ExportCommands`.

- [ ] **Step 1: Write the folder picker**

Create `Diffusely/Utilities/LibraryExportPanel.swift`:

```swift
#if os(macOS)
import AppKit

/// Folder picker for the Library export. The app is not sandboxed (the
/// entitlements file carries only iCloud keys), so the chosen URL stays usable
/// for the whole run with no security-scoped bookmark dance.
enum LibraryExportPanel {
    @MainActor
    static func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported library."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
#endif
```

- [ ] **Step 2: Write the sheet**

Create `Diffusely/Views/LibraryExportSheet.swift`:

```swift
#if os(macOS)
import SwiftUI

/// Confirm → progress → summary for one Library export. Owns the service (one
/// instance per presentation), mirroring `SortAssistantSheet`.
struct LibraryExportSheet: View {
    let destination: URL
    let indexService: LibraryIndexService

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service: LibraryExportService

    init(destination: URL, indexService: LibraryIndexService) {
        self.destination = destination
        self.indexService = indexService
        _service = StateObject(wrappedValue: .live(indexService: indexService))
    }

    private var isRunning: Bool {
        if case .exporting = service.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 20) {
            content
        }
        .padding(28)
        // macOS sheets size to their content's IDEAL height, so pin a width
        // and let the content breathe — see SortAssistantSheet's note.
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 560)
        .interactiveDismissDisabled(isRunning)
        .onDisappear { service.cancel() }
        .task { await service.prepare(destination: destination) }
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle, .preparing:
            ProgressView("Preparing…")
                .padding(.vertical, 24)

        case .confirming(let plan):
            confirmation(plan)

        case .exporting(let done, let total):
            VStack(spacing: 12) {
                Text("Exporting Library").font(.headline)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done.formatted()) of \(total.formatted())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Cancel") { service.cancel() }
                    .buttonStyle(.bordered)
            }

        case .finished(let summary):
            summaryView(summary)

        case .failed(let message):
            VStack(spacing: 16) {
                ContentUnavailableView("Can't Export",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func confirmation(_ plan: LibraryExportPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Library").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Export **\(plan.itemsToExport.formatted())** items to **\(destination.lastPathComponent)**.")
                if plan.bytesToDownload > 0 {
                    Text("\(byteText(plan.bytesToDownload)) needs downloading from iCloud first.")
                        .foregroundStyle(.secondary)
                }
                if plan.alreadyExported > 0 {
                    Text("\(plan.alreadyExported.formatted()) items are already exported and will be skipped.")
                        .foregroundStyle(.secondary)
                }
                Text("\(byteText(plan.availableBytes)) available on the destination volume.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") { service.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.itemsToExport == 0)
            }
        }
    }

    private func summaryView(_ summary: LibraryExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.cancelled ? "Export Cancelled" : "Export Complete")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(summary.exported.formatted()) items exported (\(byteText(summary.bytesWritten))).")
                if summary.skipped > 0 {
                    Text("\(summary.skipped.formatted()) already present, skipped.")
                        .foregroundStyle(.secondary)
                }
                if summary.albumsExported > 0 {
                    Text("\(summary.albumsExported.formatted()) album files exported.")
                        .foregroundStyle(.secondary)
                }
                if !summary.failures.isEmpty {
                    Text("\(summary.failures.count.formatted()) items failed — see \(LibraryExporter.failuresFileName) in the folder.")
                        .foregroundStyle(.orange)
                }
                if summary.cancelled {
                    Text("Run the export again to finish; completed items are skipped.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
```

- [ ] **Step 3: Add the focused-value key**

In `Diffusely/ContentView.swift`, inside the existing `#if os(macOS)` block, immediately after the `extension FocusedValues { var sidebarSelection … }` closing brace (around line 37), add:

```swift
/// Lets the File ▸ Export Library… command reach the frontmost Library view.
/// Published only while the Library is browsable, so the menu item disables
/// itself when the vault is locked or migrating.
struct ExportLibraryKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportLibrary: (() -> Void)? {
        get { self[ExportLibraryKey.self] }
        set { self[ExportLibraryKey.self] = newValue }
    }
}
```

- [ ] **Step 4: Add the menu command**

In `Diffusely/DiffuselyApp.swift`, inside the `#if os(macOS)` block, after `NavigationCommands` (around line 52, before the `#endif`), add:

```swift
/// File ▸ Export Library… — writes a decrypted copy of the personal Library to
/// a chosen folder. Enabled only when a browsable `LibraryView` is frontmost
/// and publishing the action.
struct ExportCommands: Commands {
    @FocusedValue(\.exportLibrary) private var exportLibrary

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Library…") {
                exportLibrary?()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportLibrary == nil)
        }
    }
}
```

Then register it in the scene's `.commands` block (around line 179), so it reads:

```swift
        .commands {
            FeedCommands()
            CollectionCommands()
            NavigationCommands()
            ExportCommands()
        }
```

- [ ] **Step 5: Wire up LibraryView**

In `Diffusely/Views/LibraryView.swift`, add to the existing `#if os(macOS)` `@State` block (after `quickLookTempURL`, around line 100):

```swift
    /// Destination chosen in the export panel; non-nil presents the sheet.
    @State private var exportDestination: URL?
```

Then in `body`, after the `.sheet(item: $editDescriptionRequest) { … }` modifier (around line 281) and before the `#if os(iOS)` settings sheet, add:

```swift
            #if os(macOS)
            .sheet(item: exportSheetRequest) { request in
                LibraryExportSheet(destination: request.url,
                                   indexService: store.indexService)
            }
            // Publish the export action ONLY while browsable, so the File menu
            // item disables itself when the vault is locked, migrating, or the
            // Library hasn't loaded — no separate enablement logic needed.
            .focusedSceneValue(\.exportLibrary, isBrowsable ? { chooseExportDestination() } : nil)
            #endif
```

And add these members near the other macOS helpers (after the Quick Look helpers, around line 875):

```swift
    #if os(macOS)
    /// `.sheet(item:)` payload — a bare `URL` isn't `Identifiable`.
    private struct ExportRequest: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var exportSheetRequest: Binding<ExportRequest?> {
        Binding(
            get: { exportDestination.map(ExportRequest.init(url:)) },
            set: { if $0 == nil { exportDestination = nil } }
        )
    }

    private func chooseExportDestination() {
        exportDestination = LibraryExportPanel.chooseDestination()
    }
    #endif
```

- [ ] **Step 6: Build both platforms**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
Then: `xcodebuild -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED for both. The iOS build proves the `#if os(macOS)` guards are complete.

- [ ] **Step 7: Run the whole export test suite**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryExportDestinationTests -only-testing:DiffuselyTests/LibraryExportPlanTests -only-testing:DiffuselyTests/LibraryExporterTests -only-testing:DiffuselyTests/LibraryExportServiceTests`
Expected: PASS, 33 tests.

- [ ] **Step 8: Verify in the running app**

Launch the built Mac app directly (do NOT run `DiffuselyUITests`). Confirm, and report what you observe:

1. With the Library **locked**, File ▸ Export Library… is greyed out.
2. With the Library **unlocked and browsable** and the Library section frontmost, the item is enabled and ⇧⌘E opens the folder panel.
3. Choosing a folder shows the confirmation with plausible counts and sizes.
4. Choosing the app's own iCloud `Items` folder shows the "choose a folder outside the container" failure instead of a confirmation.
5. Exporting a small selection produces `<id>.jpeg` / `<id>.json` pairs in the folder, and Reveal in Finder opens it.
6. Cancel mid-run stops promptly and the summary offers to re-run.

- [ ] **Step 9: Run the full test suite for regressions**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests`
Expected: PASS. If `LibraryTempMediaTests` fails with `mktemp … errno 1` (EPERM), re-run that suite alone — it is a known environmental flake on this machine, not a regression.

- [ ] **Step 10: Commit**

```bash
git add Diffusely/Utilities/LibraryExportPanel.swift Diffusely/Views/LibraryExportSheet.swift Diffusely/ContentView.swift Diffusely/DiffuselyApp.swift Diffusely/Views/LibraryView.swift
git commit -m "$(cat <<'EOF'
feat(library): File menu Export Library… command and progress sheet

macOS only. Gated on a browsable vault via a focused-scene value, so the
menu item disables itself when the Library is locked or migrating.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Output layout (`<id>.<ext>`, `<id>.json`, `album-<uuid>.json`) | 3, 4 |
| `vault.json` never exported | 3, 4 (nothing enumerates it — `vaultURLs()` puts it outside `Items/`) |
| `_DiffuselyExport-failures.txt`, deleted at run start | 6 |
| Hybrid enumeration (container for truth, index for estimate) | 2 (index rows), 3 (`enumerateMetadataFiles`) |
| Pre-flight: items, already-exported, download bytes, write bytes, free space | 2, 7 |
| Per-item loop steps 1–7 | 3 |
| Sidecars verbatim | 3 |
| Temp-then-rename, partial sweep | 3 |
| Hash mismatch exported and reported | 3 |
| Album files, sort-assistant state skipped | 4 |
| Sliding prefetch window, K = 16 | 3 (loop), 5 (tests) |
| Failures never fatal | 3 |
| Cancellation between items and inside the download poll | 5 |
| Keep the Mac awake | 7 |
| Dedicated queue, one `reconcileContext()` resolve, semaphore bridge | 3, 7 |
| Setup failures: locked, inside container, unwritable, no space | 1, 7 |
| Menu command, focused value, `NSOpenPanel`, five-state sheet | 8 |
| Progress throttled to ~10/sec | 7 |
| Tests listed in the spec | 1–7 |

No gaps.

**Notes fixed during review:**

- Task 3's `init` originally defaulted `materialize` to a non-cancellable static; Task 5 changes it to an optional parameter resolved against `shouldCancel`. Task 3's tests pass `materialize` explicitly, so they are unaffected by that change.
- `LibraryExportSummary.albumsExported` is declared in Task 1 but only populated in Task 4 — intentional, so Task 1's type is complete and Task 4 adds no new public API.
- `store.readAux(name:)` is used for plaintext album reads in Task 4 because plaintext aux names are the literal `album-<uuid>.json`, matching `LibraryAlbumStore.read(id:)`.
- Task 7's cancel latch is a lock-backed `CancelFlag`, not a main-actor `Bool`: the flag is read from the export queue and from inside the materializer's wait loop, where `MainActor.assumeIsolated` would trap.
- `ProcessInfo.beginActivity` is called from `LibraryExportService`, which is cross-platform source; the API exists on iOS too, so the file still compiles there even though nothing invokes the export on iOS.
