import XCTest
import SwiftData
@testable import Diffusely

final class LibraryIndexGenerationTests: XCTestCase {
    func testScanAppliesWhenTheGenerationIsUnchanged() {
        XCTAssertTrue(LibraryIndexService.shouldApplyScan(
            startedAtGeneration: 3, currentGeneration: 3))
    }

    func testScanIsDiscardedWhenTheRootChangedUnderIt() {
        XCTAssertFalse(LibraryIndexService.shouldApplyScan(
            startedAtGeneration: 3, currentGeneration: 4))
    }

    /// A generation can only move forward, but the predicate must not care:
    /// "different" is the whole test, so it can never be fooled into applying.
    func testAnyDifferenceDiscardsTheScan() {
        XCTAssertFalse(LibraryIndexService.shouldApplyScan(
            startedAtGeneration: 5, currentGeneration: 2))
    }

    // MARK: - End-to-end: `reconcile` actually honors the generation it is handed

    // The tests above only exercise the pure predicate. Nothing above proves
    // `reconcile` actually consults it before applying a scan — deleting the
    // staleness `guard` in `reconcile` (immediately before `applyScan`) leaves
    // all three green. These two drive `reconcile` itself so that removing the
    // guard breaks a test.

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeItemSidecar(_ id: Int, in dir: URL) throws {
        let meta = LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: id, sourcePostID: nil,
            sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(id)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t")
        let data = try LibraryItemMetadata.encoder().encode(meta)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    /// Seeds the index from a real directory, then reconciles against an EMPTY
    /// directory (a legitimate "every sidecar vanished" scan) while asserting
    /// the caller's generation has already moved on. The guard must discard
    /// this scan wholesale — a scan of the old root must never prune the new
    /// root's rows it never looked at.
    func testReconcileDiscardsAScanWhoseGenerationHasMovedOn() async throws {
        let seededDir = tempDir()
        defer { try? FileManager.default.removeItem(at: seededDir) }
        try writeItemSidecar(1, in: seededDir)
        try writeItemSidecar(2, in: seededDir)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: seededDir)
        let seededCount = await index.itemCount()
        XCTAssertEqual(seededCount, 2, "precondition: the index must actually hold the seeded rows")

        let emptyDir = tempDir()
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let outcome = await index.reconcile(
            itemsDirectory: emptyDir,
            startedAtGeneration: 1,
            generationProbe: { 2 }
        )

        XCTAssertEqual(outcome, .didNotScan)
        let countAfter = await index.itemCount()
        XCTAssertEqual(countAfter, 2, "a scan of a root that changed underneath it must not prune rows it never saw")
    }

    /// Mirror image: same setup, but the generation has NOT moved. The empty
    /// directory is then a legitimate scan of the CURRENT root, so the prune
    /// must go through — proving the guard only rejects a genuinely stale scan,
    /// not every scan.
    func testReconcileAppliesAScanWhoseGenerationIsUnchanged() async throws {
        let seededDir = tempDir()
        defer { try? FileManager.default.removeItem(at: seededDir) }
        try writeItemSidecar(1, in: seededDir)
        try writeItemSidecar(2, in: seededDir)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: seededDir)
        let seededCount = await index.itemCount()
        XCTAssertEqual(seededCount, 2, "precondition: the index must actually hold the seeded rows")

        let emptyDir = tempDir()
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let outcome = await index.reconcile(
            itemsDirectory: emptyDir,
            startedAtGeneration: 1,
            generationProbe: { 1 }
        )

        XCTAssertNotEqual(outcome, .didNotScan)
        let countAfter = await index.itemCount()
        XCTAssertEqual(countAfter, 0, "an unchanged-generation scan of an empty directory must prune every row")
    }
}
