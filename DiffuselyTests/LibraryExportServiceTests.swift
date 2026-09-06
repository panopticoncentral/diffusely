import XCTest
import CryptoKit
import Combine
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

    /// A half-encrypted container is unlocked (so the `.locked` guard passes)
    /// but reports `isEncrypted == true`, so the engine would enumerate only
    /// `*.m` and silently omit every leftover plaintext `<id>.json` sidecar —
    /// a short export presented as a complete one. The service must refuse it
    /// itself, not rely on the UI's `libraryGate` having done so.
    @MainActor
    func testPrepareRefusesAHalfEncryptedContainer() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(
            itemsDirectory: container,
            crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        // A leftover plaintext sidecar: exactly what a partial/failed
        // encryption enable leaves behind.
        try Data("{}".utf8).write(to: container.appendingPathComponent("1.json"))

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })
        await service.prepare(destination: destination)

        guard case .failed(let message) = service.phase else {
            return XCTFail("expected .failed, got \(service.phase)")
        }
        XCTAssertEqual(message, LibraryExportError.setupIncomplete.errorDescription)
    }

    /// The same encrypted store with nothing left in plaintext must still be
    /// exportable — the guard is about the half-migrated state, not about
    /// encryption.
    @MainActor
    func testPrepareAllowsAFullyEncryptedContainer() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(
            itemsDirectory: container,
            crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        try store.writeMetadata(Data("{}".utf8), itemID: 1)

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })
        await service.prepare(destination: destination)

        guard case .confirming = service.phase else {
            return XCTFail("expected .confirming, got \(service.phase)")
        }
    }

    /// I3: an empty (or stale, or rebuild-pending) index must not make the
    /// export unreachable. The plan still confirms, and its `indexedItems` is
    /// carried into the run so the summary can flag a shortfall.
    @MainActor
    func testPrepareConfirmsEvenWhenTheIndexIsEmpty() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        let service = LibraryExportService(
            resolveContext: { (.notConfigured, store) },
            sizingRows: { [] })

        await service.prepare(destination: destination)

        guard case .confirming(let plan) = service.phase else {
            return XCTFail("expected .confirming, got \(service.phase)")
        }
        XCTAssertEqual(plan.itemsToExport, 0)
        XCTAssertEqual(plan.indexedItems, 0)
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

    /// The progress bar must not be seeded from the index estimate and then
    /// overwritten by the container's real total ("Export 3 items" followed by
    /// "1 of 6,220" reads as a glitch). It starts indeterminate.
    @MainActor
    func testExportingStartsWithNoTotalUntilTheEngineReportsOne() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        try seedItems(1, in: store)

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [LibraryExportSizingRow(itemID: 99, mediaFileName: "99.jpeg",
                                                  fileByteSize: 1, isEvicted: false)] })
        await service.prepare(destination: destination)
        service.start()

        // `start()` is synchronous up to the `Task`, so this is deterministic.
        XCTAssertEqual(service.phase, .exporting(done: 0, total: nil))

        for _ in 0..<400 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .finished = service.phase else {
            return XCTFail("expected .finished, got \(service.phase)")
        }
    }

    /// The index's count has to reach the engine, or the summary can't tell a
    /// short container walk from a complete one.
    @MainActor
    func testIndexCountIsCarriedIntoTheSummaryAndFlagsAShortWalk() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        try seedItems(1, in: store)

        let rows = (1...4).map {
            LibraryExportSizingRow(itemID: $0, mediaFileName: "\($0).jpeg",
                                   fileByteSize: 1, isEvicted: false)
        }
        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { rows })
        await service.prepare(destination: destination)
        service.start()

        for _ in 0..<400 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .finished(let summary) = service.phase else {
            return XCTFail("expected .finished, got \(service.phase)")
        }
        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.indexedItems, 4)
        XCTAssertEqual(summary.enumeratedItems, 1)
        XCTAssertEqual(summary.indexShortfall, 3)
        XCTAssertTrue(summary.isPotentiallyIncomplete)
    }

    /// The pre-flight now does real, blocking filesystem work on the export
    /// queue, so cancelling during `.preparing` must actually stop it
    /// publishing a phase instead of being ignored.
    @MainActor
    func testCancelDuringPreparingStopsThePreflight() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)

        final class ServiceBox: @unchecked Sendable { var service: LibraryExportService? }
        let box = ServiceBox()
        let service = LibraryExportService(
            resolveContext: { (.notConfigured, store) },
            // Cancel lands while the pre-flight is mid-flight.
            sizingRows: {
                await MainActor.run { box.service?.cancel() }
                return []
            })
        box.service = service

        await service.prepare(destination: destination)

        XCTAssertEqual(service.phase, .preparing,
                       "a cancelled pre-flight must not go on to publish a plan")
    }

    // MARK: Cancellation

    /// Writes `count` valid, independent item sidecars + media files directly
    /// into `store`, so a real `LibraryExporter.run` has real work to do.
    private func seedItems(_ count: Int, in store: LibraryFileStore) throws {
        for id in 1...count {
            let media = Data("m\(id)".utf8)
            let sha = SHA256.hash(data: media).map { String(format: "%02x", $0) }.joined()
            let sidecar = Data("""
            {"schemaVersion":6,"itemID":\(id),"canonicalPageURL":"x","sourceDomain":"civitai.com",\
            "originalCDNURL":"x","mediaType":"image","mediaFileName":"\(id).jpeg","fileByteSize":1,\
            "contentSHA256":"\(sha)","width":1,"height":1,"nsfwLevel":1,"author":{},\
            "albumIDs":[],"savedAt":"2026-01-01T00:00:00Z","savedByAppVersion":"t"}
            """.utf8)
            try store.writeMetadata(sidecar, itemID: id)
            try store.writeMedia(media, itemID: id, plaintextExtension: "jpeg")
        }
    }

    /// A fresh `CancelFlag` is installed per `start()`. Cancelling run 1 must
    /// not poison run 2 on the same service instance.
    @MainActor
    func testCancelFlagIsFreshPerRun() async throws {
        let container = try makeDir()
        let dest1 = try makeDir(), dest2 = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        try seedItems(1, in: store)

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })

        // Run 1: cancel it before it can do any real work. `start()` and
        // `cancel()` are both synchronous main-actor calls with no `await`
        // between them, so `cancel()` is guaranteed to set the flag before
        // the background `Task`'s closure gets a chance to run — this half
        // is a deterministic assertion, not a timing race.
        await service.prepare(destination: dest1)
        service.start()
        service.cancel()

        for _ in 0..<400 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .finished(let summary1) = service.phase else {
            return XCTFail("expected run 1 .finished, got \(service.phase)")
        }
        XCTAssertTrue(summary1.cancelled)

        // Run 2: if the flag were not replaced in `start()`, this would
        // inherit run 1's tripped flag and cancel immediately too.
        await service.prepare(destination: dest2)
        service.start()

        for _ in 0..<400 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .finished(let summary2) = service.phase else {
            return XCTFail("expected run 2 .finished, got \(service.phase)")
        }
        XCTAssertFalse(summary2.cancelled)
        XCTAssertEqual(summary2.exported, 1)
        XCTAssertEqual(try Data(contentsOf: dest2.appendingPathComponent("1.jpeg")),
                       Data("m1".utf8))
    }

    /// Cancelling a run genuinely in progress (not just at the starting
    /// gate) still produces a `.finished` summary with `cancelled == true`.
    ///
    /// Not perfectly deterministic — a true mid-run cancel depends on this
    /// test's polling catching the export between items — but generous: 500
    /// tiny items give the background run a wide window to still be
    /// mid-flight when `cancel()` lands, and the first assertion fails
    /// loudly (rather than hanging) if the export ever legitimately outruns
    /// the poll instead.
    @MainActor
    func testCancelMidRunProducesACancelledSummary() async throws {
        let container = try makeDir(), destination = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        try seedItems(500, in: store)

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })
        await service.prepare(destination: destination)
        service.start()

        var sawInProgress = false
        for _ in 0..<1000 {
            if case .exporting = service.phase {
                sawInProgress = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(sawInProgress, "export never reported .exporting before finishing")

        service.cancel()

        for _ in 0..<1000 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard case .finished(let summary) = service.phase else {
            return XCTFail("expected .finished, got \(service.phase)")
        }
        XCTAssertTrue(summary.cancelled)
    }

    // MARK: Reentrancy

    /// The regression guard for the reentrancy fix: a second `prepare()`
    /// while an earlier run is still in flight must not let that earlier
    /// run's eventual completion overwrite the newer phase this call
    /// produces. Deterministic under the fix, because `prepare()` cancels
    /// and fully awaits the superseded run before touching `phase` again —
    /// so by the time this method returns, run 1 has already written
    /// whatever it was going to write, and nothing further from it can land.
    @MainActor
    func testSupersededRunDoesNotOverwriteNewerPhase() async throws {
        let container = try makeDir()
        let dest1 = try makeDir(), dest2 = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        try seedItems(1, in: store)

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })

        await service.prepare(destination: dest1)
        service.start() // run 1 begins

        // Supersede it before it has a chance to finish on its own.
        await service.prepare(destination: dest2)

        guard case .confirming = service.phase else {
            return XCTFail("expected run 2's .confirming, got \(service.phase)")
        }

        // Give run 1 every opportunity to finish naturally and try to
        // clobber this phase — it has one tiny item, so left unsupervised it
        // would complete in milliseconds.
        try await Task.sleep(nanoseconds: 500_000_000)
        guard case .confirming = service.phase else {
            return XCTFail("run 1's completion overwrote run 2's phase: \(service.phase)")
        }

        // And run 2 itself must still be able to complete normally.
        service.start()
        for _ in 0..<400 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .finished(let summary2) = service.phase else {
            return XCTFail("expected run 2 .finished, got \(service.phase)")
        }
        XCTAssertFalse(summary2.cancelled)
        XCTAssertEqual(summary2.exported, 1)
    }

    /// The regression guard for the token fix: a superseded run's completion
    /// (and any late progress tick) must never *publish* `.finished` to
    /// observers of `@Published phase` — not even transiently, and not even
    /// if a later write immediately overwrites it. `testSupersededRunDoesNot-
    /// OverwriteNewerPhase` above only checks `phase` after the fact, which
    /// is exactly why it cannot see this: a value that was published and
    /// then instantly overwritten is invisible to a snapshot read. This test
    /// subscribes to `service.$phase` with a Combine sink and records every
    /// value as it is published, continuously, across the supersede.
    @MainActor
    func testSupersededRunNeverPublishesStaleFinished() async throws {
        let container = try makeDir()
        let dest1 = try makeDir(), dest2 = try makeDir()
        let store = LibraryFileStore(itemsDirectory: container, crypto: nil)
        try seedItems(1, in: store)

        let service = LibraryExportService(
            resolveContext: { (.unlocked, store) },
            sizingRows: { [] })

        var recorded: [LibraryExportService.Phase] = []
        let cancellable = service.$phase.sink { recorded.append($0) }
        defer { cancellable.cancel() }

        await service.prepare(destination: dest1)
        service.start() // run 1 begins

        // The window that matters starts *before* the superseding
        // `prepare()` call, not after it returns: the bug this test guards
        // against is run 1's completion publishing `.finished` from inside
        // that call's own cancel-and-await join, before it goes on to
        // publish `.preparing`/`.confirming` for run 2 — i.e., strictly
        // between this point and run 2's own `start()` below. Capturing the
        // boundary only after `prepare()` returns would already be too late
        // to see it (this was verified as part of the mutation check: see
        // the task-7-report.md fix report for the false-negative it
        // produced on the first attempt).
        let beforeSupersedeIndex = recorded.count

        // Supersede it before it has a chance to finish on its own.
        await service.prepare(destination: dest2)
        guard case .confirming = service.phase else {
            return XCTFail("expected run 2's .confirming, got \(service.phase)")
        }

        // Give run 1 every further opportunity to finish naturally and try
        // to publish a late, stale `.finished` — it has one tiny item, so
        // left unsupervised it would complete in milliseconds, well inside
        // this window.
        try await Task.sleep(nanoseconds: 500_000_000)
        let beforeSecondStartIndex = recorded.count

        let quietWindow = recorded[beforeSupersedeIndex..<beforeSecondStartIndex]
        if let stale = quietWindow.first(where: { if case .finished = $0 { return true }; return false }) {
            XCTFail("run 1's completion published a stale .finished while " +
                     "run 2 was superseding it: \(stale)")
        }

        // Run 2 itself must still be able to complete normally, and its own
        // completion must actually appear in the recorded sequence — this
        // isn't just checking that nothing was ever published.
        service.start()
        for _ in 0..<400 {
            if case .finished = service.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .finished(let summary2) = service.phase else {
            return XCTFail("expected run 2 .finished, got \(service.phase)")
        }
        XCTAssertFalse(summary2.cancelled)
        XCTAssertEqual(summary2.exported, 1)
        XCTAssertTrue(recorded.contains { if case .finished = $0 { return true }; return false },
                       "run 2's own .finished was never observed in the recorded sequence")
    }
}
