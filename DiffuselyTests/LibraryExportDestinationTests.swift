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

    // MARK: Container-root guard

    private func makeTree(_ components: String...) throws -> URL {
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `<ubiquityRoot>/Documents/Backup` is a SIBLING of `Items/`, so guarding
    /// `Items/` alone let it through — writing a full plaintext, decrypted
    /// copy of an at-rest-encrypted Library into the same iCloud container,
    /// to be uploaded. The guard covers the container root.
    func testRefusesASiblingOfItemsInsideTheUbiquityContainer() throws {
        let items = try makeTree("Documents", "Items")
        let root = items.deletingLastPathComponent().deletingLastPathComponent()
        let backup = root.appendingPathComponent("Documents/Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: backup, itemsDirectory: items)) { error in
            XCTAssertEqual(error as? LibraryExportError, .destinationInsideContainer)
        }
        // And anywhere else under the container root, not just under Documents.
        let atRoot = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: atRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: atRoot, itemsDirectory: items))
    }

    /// The local-fallback layout is `<Application Support>/Library/Items`, so
    /// the app's own `Library` folder (which also holds `vault.json`) is the
    /// protected root there — and NOT its parent, which would be a guard over
    /// all of Application Support.
    func testLocalFallbackProtectsTheAppLibraryFolderButNotItsParent() throws {
        let items = try makeTree("Library", "Items")
        let appLibrary = items.deletingLastPathComponent()
        let inside = appLibrary.appendingPathComponent("Backup", isDirectory: true)
        let outside = appLibrary.deletingLastPathComponent()
            .appendingPathComponent("Backup", isDirectory: true)
        for url in [inside, outside] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: inside, itemsDirectory: items)) { error in
            XCTAssertEqual(error as? LibraryExportError, .destinationInsideContainer)
        }
        XCTAssertNoThrow(try LibraryExportDestination.validate(
            destination: outside, itemsDirectory: items))
    }

    /// An items directory matching neither of `LibraryContainer`'s two real
    /// layouts protects exactly itself — the guard never widens a whole parent
    /// tree on the strength of a folder called `Items`, which would refuse
    /// destinations having nothing to do with the Library (see
    /// `testSiblingWithSharedPrefixIsAccepted` above).
    func testUnrecognizedItemsLayoutProtectsOnlyItself() throws {
        let items = try makeTree("Somewhere", "Items")
        let sibling = try makeDir("Elsewhere")

        XCTAssertEqual(LibraryExportDestination.protectedRoot(forItemsDirectory: items), items)
        XCTAssertThrowsError(try LibraryExportDestination.validate(
            destination: items, itemsDirectory: items))
        XCTAssertNoThrow(try LibraryExportDestination.validate(
            destination: sibling, itemsDirectory: items))
    }
}
