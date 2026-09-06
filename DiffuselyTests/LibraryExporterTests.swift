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

    /// Both files land on the destination, so both must be counted. Media
    /// alone under-reported every run.
    func testBytesWrittenCountsMediaAndSidecar() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let media = Data("media-bytes-15".utf8)
        let sidecar = try seed(store, id: 15, media: media)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.bytesWritten, media.count + sidecar.count)
    }

    /// One item must never produce two failures. A hash mismatch whose write
    /// then fails is ONE failed item (the write), not "2 items failed".
    func testMismatchedItemWhoseWriteFailsReportsASingleFailure() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 16, media: Data("m16".utf8),
                 sha: String(repeating: "0", count: 64))

        // A directory squatting on the media file's `.partial` path makes
        // `Data.write(to:)` throw, exactly as in
        // `testFailuresFileIncludesAlbumWriteFailures`. Planted from inside
        // `materialize` so `run`'s up-front `.partial` sweep can't remove it.
        let partial = destination.appendingPathComponent(".16.jpeg.partial")
        let instrumented = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in
                try? FileManager.default.createDirectory(
                    at: partial, withIntermediateDirectories: true)
                return nil
            },
            startPrefetch: { _ in },
            shouldCancel: { false })

        let summary = instrumented.run { _, _ in }

        XCTAssertEqual(summary.exported, 0)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.itemID, 16)
        guard case .writeFailed = summary.failures.first?.reason else {
            return XCTFail("expected writeFailed, got \(String(describing: summary.failures.first?.reason))")
        }
    }

    // MARK: Index-vs-container delta (a short run must not read as success)

    func testSummaryRecordsTheEnumeratedAndIndexedCounts() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 90...92 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        let summary = LibraryExporter(
            store: store, destination: destination, indexedItemCount: 3,
            materialize: { _ in nil }, startPrefetch: { _ in }, shouldCancel: { false })
            .run { _, _ in }

        XCTAssertEqual(summary.enumeratedItems, 3)
        XCTAssertEqual(summary.indexedItems, 3)
        XCTAssertEqual(summary.indexShortfall, 0)
        XCTAssertEqual(summary.indexSurplus, 0)
        XCTAssertFalse(summary.isPotentiallyIncomplete)
    }

    /// The C1 case: the container walk sees far fewer files than the index
    /// expected (evicted container, unresolved directory, a swallowed
    /// `contentsOfDirectory` failure). The run must not present as complete.
    func testShortContainerWalkAgainstTheIndexIsFlaggedIncomplete() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 93, media: Data("m93".utf8))

        let summary = LibraryExporter(
            store: store, destination: destination, indexedItemCount: 6_214,
            materialize: { _ in nil }, startPrefetch: { _ in }, shouldCancel: { false })
            .run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.failures, [])
        XCTAssertEqual(summary.enumeratedItems, 1)
        XCTAssertEqual(summary.indexShortfall, 6_213)
        XCTAssertTrue(summary.isPotentiallyIncomplete)
    }

    /// The worst shape of all: nothing enumerated, nothing exported, nothing
    /// failed. Flagged even when the index has no estimate to compare against.
    func testEmptyContainerWalkIsFlaggedIncompleteEvenWithoutAnIndexEstimate() throws {
        let container = try makeDir(), destination = try makeDir()

        let summary = exporter(plaintextStore(container), destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 0)
        XCTAssertEqual(summary.enumeratedItems, 0)
        XCTAssertEqual(summary.indexedItems, 0)
        XCTAssertTrue(summary.isPotentiallyIncomplete)
    }

    /// The spec's other direction — "6 items on disk weren't in the index".
    /// Informational only: the container is truth, so they are exported.
    func testItemsOnDiskThatTheIndexDidNotKnowAboutAreReportedAsASurplus() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 94...97 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        let summary = LibraryExporter(
            store: store, destination: destination, indexedItemCount: 1,
            materialize: { _ in nil }, startPrefetch: { _ in }, shouldCancel: { false })
            .run { _, _ in }

        XCTAssertEqual(summary.exported, 4)
        XCTAssertEqual(summary.indexSurplus, 3)
        XCTAssertEqual(summary.indexShortfall, 0)
        XCTAssertFalse(summary.isPotentiallyIncomplete)
    }

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

    /// Regression test for a bug where a plaintext store's
    /// `enumerateMetadataFiles()` (which classifies by the bare `*.json`
    /// suffix) handed the album's own `album-<uuid>.json` file to the item
    /// pass as if it were an item sidecar, which then failed to decode it as
    /// `LibraryItemMetadata` and recorded a spurious `.sidecarUndecodable`
    /// failure — even though the album itself exports fine via the separate
    /// album pass. A clean plaintext export with an album must report zero
    /// failures and leave no failures file behind.
    func testPlaintextExportWithAlbumReportsNoFailures() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 80, media: Data("m80".utf8))
        let album = makeAlbum("Mixed")
        try LibraryAlbumStore(store: store).write(album)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.albumsExported, 1)
        XCTAssertEqual(summary.failures, [])
        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
    }

    /// Same bug, different contaminating file: `SortAssistantStateStore`
    /// writes its state as a literal `sort-assistant-state.json` in the same
    /// plaintext `itemsDirectory` as item sidecars, so it also matched the
    /// bare `*.json` classification and was fed to the item pass.
    func testPlaintextExportWithSortAssistantStateReportsNoFailures() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 81, media: Data("m81".utf8))
        try store.writeAux(Data("{\"reviewed\":[]}".utf8),
                           name: SortAssistantStateStore.fileName)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.failures, [])
        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
    }

    /// An album file that can't be READ is a real failure and must be
    /// reported — every other omission in this engine is. Here the file fails
    /// to decrypt, which on the encrypted side is never the classification
    /// path (that's a *decode* failure on successfully-read bytes).
    func testUnreadableEncryptedAlbumFileIsReportedAsAFailure() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = encryptedStore(container)
        try LibraryAlbumStore(store: store).write(makeAlbum("Good"))
        // Undecryptable bytes under a well-formed opaque `.x` name.
        try Data("not a sealed box".utf8)
            .write(to: container.appendingPathComponent("deadbeefdeadbeef.x"))

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.albumsExported, 1)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.fileName, "deadbeefdeadbeef.x")
        XCTAssertEqual(summary.failures.first?.reason, .albumUnreadable)
    }

    func testUnreadablePlaintextAlbumFileIsReportedAsAFailure() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        let name = LibraryAlbumStore.fileName(for: UUID())
        // A directory where the album file should be: correctly named, and
        // unreadable — `Data(contentsOf:)` throws on it.
        try FileManager.default.createDirectory(
            at: container.appendingPathComponent(name), withIntermediateDirectories: true)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.albumsExported, 0)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.fileName, name)
        XCTAssertEqual(summary.failures.first?.reason, .albumUnreadable)
    }

    /// The load-bearing counterpart to the two tests above: on an encrypted
    /// store a *decode* failure is how sort-assistant state is classified out
    /// of the shared opaque `.x` namespace, so it must stay silent. Reporting
    /// it would make every encrypted export claim a failure.
    func testEncryptedSortAssistantStateProducesNoFailure() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = encryptedStore(container)
        try store.writeAux(Data("{\"reviewed\":[]}".utf8),
                           name: SortAssistantStateStore.fileName)

        let summary = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(summary.albumsExported, 0)
        XCTAssertEqual(summary.failures, [])
        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
    }

    func testRerunSkipsAlbumsAlreadyExported() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try LibraryAlbumStore(store: store).write(makeAlbum("Sketches"))

        _ = exporter(store, destination).run { _, _ in }
        let second = exporter(store, destination).run { _, _ in }

        XCTAssertEqual(second.albumsExported, 0)
    }

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

    /// Cancel lands while `materialize` is blocked on an evicted file, so the
    /// bridged download unwinds with `CancellationError` — the real shape of
    /// cancellation on the fully-evicted library this feature exists for.
    ///
    /// Every other cancellation test here injects `materialize: { _ in nil }`
    /// (or runs against an all-local plaintext store where `isReady`
    /// short-circuits), so none of them can see this: the read-ahead loop had
    /// no cancellation check of its own and kept preparing until the 16-slot
    /// window filled, turning one deliberate Cancel into up to 17
    /// `.downloadFailed` entries, a failures file claiming they failed, and a
    /// sheet reading "17 items failed".
    func testCancellationDuringMaterializeRecordsNoFailures() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 100...109 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        var cancelled = false
        var materializations = 0
        var materializationsAfterCancel = 0
        let cancelling = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in
                // Once cancelled, every in-flight and subsequent wait returns
                // immediately with CancellationError — what `blockingRun`
                // does after it cancels the bridged `Task`.
                if cancelled {
                    materializationsAfterCancel += 1
                    return CancellationError()
                }
                materializations += 1
                // Cancel lands mid-materialize on the third file.
                if materializations == 3 {
                    cancelled = true
                    return CancellationError()
                }
                return nil
            },
            startPrefetch: { _ in },
            shouldCancel: { cancelled })

        let summary = cancelling.run { _, _ in }

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.failures, [],
                       "a cancelled run must not report its abandoned downloads as failures")
        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
        // The read-ahead cursor must stop too, not keep preparing until its
        // 16-slot window fills: after the flag trips there is only the
        // in-flight write cursor's own media wait left to unwind.
        XCTAssertLessThanOrEqual(materializationsAfterCancel, 2,
                                 "the read-ahead cursor kept working after Cancel")
        // And the partial export it leaves behind is still valid and resumable.
        XCTAssertFalse(names(in: destination).contains { $0.hasSuffix(".partial") })
        let resumed = exporter(store, destination).run { _, _ in }
        XCTAssertEqual(resumed.exported + resumed.skipped, 10)
        XCTAssertEqual(resumed.failures, [])
    }

    /// The read-ahead cursor's own side of the same fix. When Cancel lands on
    /// the very first sidecar materialize, that abandoned item is the only
    /// thing in the queue, so the write cursor consumes it in the same
    /// iteration — and it must be dropped there too, not recorded as a
    /// `.downloadFailed`.
    func testCancellationOnTheVeryFirstItemRecordsNoFailure() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 110...115 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        var cancelled = false
        let cancelling = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in
                cancelled = true
                return CancellationError()
            },
            startPrefetch: { _ in },
            shouldCancel: { cancelled })

        let summary = cancelling.run { _, _ in }

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.exported, 0)
        XCTAssertEqual(summary.failures, [])
        XCTAssertFalse(names(in: destination).contains(LibraryExporter.failuresFileName))
    }

    /// Regression for the inner read-ahead `break` that could exit the run
    /// loop with the cancel flag observed true but `summary.cancelled` left
    /// `false`. Reachable specifically on the very first iteration, while
    /// `queue` is still empty: the outer check (call 1) must answer false so
    /// the loop falls into the top-up `while`, and the FIRST check inside
    /// that inner loop (call 2) must answer true so it breaks having appended
    /// nothing. The outer `guard !queue.isEmpty else { break }` then exits the
    /// whole run with nothing exported — and, before the fix, with
    /// `cancelled` never set. A `written`-keyed cancel flag (as the other
    /// cancellation tests use) can't reach this: it takes a call-count-keyed
    /// flag with values chosen precisely for the outer/inner pair.
    func testCancellationBetweenOuterAndInnerChecksWithEmptyQueueMarksCancelled() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        for id in 200...205 { try seed(store, id: id, media: Data("m\(id)".utf8)) }

        var calls = 0
        let cancelling = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in nil },
            startPrefetch: { _ in },
            shouldCancel: {
                calls += 1
                // Call 1 is the outer check on the first pass through `while
                // true`, with `queue` still empty: answer false so control
                // reaches the inner top-up loop. Call 2 is that loop's own
                // first check: answer true so it breaks immediately, leaving
                // `queue` empty for the outer `guard` to exit on.
                return calls > 1
            })

        let summary = cancelling.run { _, _ in }

        XCTAssertTrue(summary.cancelled,
                      "cancelling between the outer and inner checks with an "
                      + "empty queue must still mark the run cancelled, not "
                      + "let it read as a completed export")
        XCTAssertEqual(summary.exported, 0)
        XCTAssertEqual(summary.failures, [])
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

    // MARK: blockingRun (async-to-blocking cancellation bridge)

    /// Test-only marker error, distinct from anything `blockingRun` itself
    /// might throw.
    private struct MarkerError: Error, Equatable {}

    /// Runs `LibraryExporter.blockingRun` on a dedicated background queue —
    /// never the test's own thread, and never Swift concurrency's
    /// cooperative pool — mirroring how `LibraryExportService` calls the
    /// exporter from its own dedicated queue rather than from an async
    /// context. That keeps the semaphore wait inside `blockingRun` from ever
    /// contending with the very `Task` it's waiting on. `XCTestExpectation`'s
    /// timeout means a regression that fails to unblock fails this test
    /// instead of hanging the run.
    private func runBlocking(
        tickInterval: TimeInterval = 0.01,
        shouldCancel: @escaping () -> Bool,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Error? {
        let done = expectation(description: "blockingRun returned")
        final class ResultBox: @unchecked Sendable { var error: Error? }
        let box = ResultBox()
        DispatchQueue.global().async {
            box.error = LibraryExporter.blockingRun(
                tickInterval: tickInterval, shouldCancel: shouldCancel, operation: operation)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return box.error
    }

    func testBlockingRunCompletesFastOperationWithNoError() {
        let result = runBlocking(shouldCancel: { false }) { }
        XCTAssertNil(result)
    }

    func testBlockingRunSurfacesTheThrownError() {
        let result = runBlocking(shouldCancel: { false }) { throw MarkerError() }
        XCTAssertEqual(result as? MarkerError, MarkerError())
    }

    /// Cancellation is the whole point of the tick loop: a `shouldCancel`
    /// that's already true must cut a many-second wait down to a couple of
    /// ticks, not let it run to completion.
    func testBlockingRunCancelsASlowOperationPromptly() {
        let start = Date()
        let result = runBlocking(tickInterval: 0.02, shouldCancel: { true }) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result is CancellationError,
                      "expected CancellationError, got \(String(describing: result))")
        XCTAssertLessThan(elapsed, 1.0, "cancellation should cut the 5s sleep short")
    }

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

    /// Guards the ordering correction: the report must be written AFTER
    /// `exportAlbums`, because album writes can themselves append to
    /// `summary.failures`. This forces a failure that can only originate in
    /// the album pass and asserts it shows up in the report — if the write
    /// moved back above `exportAlbums`, this failure would never make it
    /// into the file.
    ///
    /// Uses `plaintextStore`: this used to require `encryptedStore` to dodge
    /// a since-fixed bug where a plaintext store's item pass independently
    /// (mis)classified `album-<uuid>.json` as an item sidecar and recorded
    /// its own unrelated `.sidecarUndecodable` failure for it, contaminating
    /// this assertion. Now that `isItemSidecar` filters those out, plaintext
    /// exercises the same album-write failure cleanly — see
    /// `testPlaintextExportWithAlbumReportsNoFailures` for the regression
    /// test covering that fix directly.
    func testFailuresFileIncludesAlbumWriteFailures() throws {
        let container = try makeDir(), destination = try makeDir()
        let store = plaintextStore(container)
        try seed(store, id: 70, media: Data("m70".utf8))
        let album = makeAlbum("Broken")
        try LibraryAlbumStore(store: store).write(album)

        // `writeAtomically` writes to `.<name>.partial` before renaming it
        // onto the final name. Putting a directory at that partial path
        // makes `Data.write(to:)` throw, so the album write fails with
        // `.writeFailed` without touching any production code. This is NOT
        // the final name, so `exportAlbums`'s skip-if-already-exists check
        // (which only inspects the final name) does not trip.
        //
        // The directory can't be planted from the test body up front: `run`
        // sweeps every `.partial` entry out of the destination before doing
        // any work, so it would just be deleted before `exportAlbums` runs.
        // Planting it from inside `materialize` — which only starts firing
        // once item processing begins, after the sweep — lands it after the
        // sweep and lets it survive to block the album write.
        let albumName = LibraryAlbumStore.fileName(for: album.id)
        let partial = destination.appendingPathComponent(".\(albumName).partial")
        let instrumented = LibraryExporter(
            store: store, destination: destination,
            materialize: { _ in
                try? FileManager.default.createDirectory(
                    at: partial, withIntermediateDirectories: true)
                return nil
            },
            startPrefetch: { _ in },
            shouldCancel: { false })

        let summary = instrumented.run { _, _ in }

        XCTAssertEqual(summary.exported, 1)
        XCTAssertEqual(summary.albumsExported, 0)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.fileName, albumName)
        guard case .writeFailed = summary.failures.first?.reason else {
            return XCTFail("expected writeFailed, got \(String(describing: summary.failures.first?.reason))")
        }

        let report = try XCTUnwrap(data(destination, LibraryExporter.failuresFileName))
        let text = try XCTUnwrap(String(data: report, encoding: .utf8))
        XCTAssertTrue(text.contains(albumName), text)
    }
}
