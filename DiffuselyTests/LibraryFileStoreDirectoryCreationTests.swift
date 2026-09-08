import XCTest
@testable import Diffusely

/// Covers `LibraryFileStore.createsContainerDirectory` (Step 6): a custom root
/// belongs to the user, so a store bound to one must never recreate its items
/// directory after the volume it lived on goes away — recreating it would
/// manufacture an empty Library at a dead mount point, which a later
/// reconcile would read as "every item was deleted".
final class LibraryFileStoreDirectoryCreationTests: XCTestCase {
    private func unusedDir() -> URL {
        // A path under a fresh UUID that is never created — stands in for a
        // vanished custom-root mount point.
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testCreatesContainerDirectoryFalseSuppressesDirectoryCreation() throws {
        let dir = unusedDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil, createsContainerDirectory: false)
        // The write itself is expected to fail (the directory isn't there),
        // but that failure must come from the missing directory, not from
        // anything else — the point of this test is what happens to the
        // directory, not the exact error.
        XCTAssertThrowsError(try store.writeMetadata(Data("{}".utf8), itemID: 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "createsContainerDirectory: false must not create the items directory")
    }

    func testDefaultCreatesContainerDirectoryTrueCreatesDirectoryOnWrite() throws {
        let dir = unusedDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        // Default (createsContainerDirectory: true) — matches every existing
        // call site in this codebase (the iCloud container).
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(Data("{}".utf8), itemID: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                       "the default must create the items directory on write")
        XCTAssertEqual(store.readMetadata(itemID: 1), Data("{}".utf8),
                       "the write itself must have succeeded — proves the directory creation is what made the difference, not an unrelated write failure")
    }
}
