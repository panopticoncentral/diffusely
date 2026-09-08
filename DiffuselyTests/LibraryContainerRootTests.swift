import XCTest
@testable import Diffusely

final class LibraryContainerRootTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryContainerRootTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeContainer() -> LibraryContainer {
        let defaults = UserDefaults(suiteName: "LibraryContainerRootTests-\(UUID().uuidString)")!
        return LibraryContainer(rootStore: LibraryRootStore(defaults: defaults))
    }

    func testCustomRootResolvesToTheChosenFolderItself() async throws {
        let container = makeContainer()
        await container.setRoot(.custom(tempRoot))
        let resolved = try await container.itemsDirectory()
        XCTAssertEqual(resolved.standardizedFileURL, tempRoot.standardizedFileURL)
    }

    /// The critical one: an unplugged volume must not have a Library folder
    /// conjured at its mount point, which reconcile would read as "empty".
    func testMissingCustomRootThrowsAndIsNotCreated() async {
        let container = makeContainer()
        let missing = tempRoot.appendingPathComponent("unplugged", isDirectory: true)
        await container.setRoot(.custom(missing))

        do {
            _ = try await container.itemsDirectory()
            XCTFail("expected itemsDirectory() to throw for a missing custom root")
        } catch let error as LibraryRootError {
            XCTAssertEqual(error, .unavailable(missing))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "a missing custom root must never be created")
    }

    func testVaultURLsThrowForACustomRoot() async {
        let container = makeContainer()
        await container.setRoot(.custom(tempRoot))
        do {
            _ = try await container.vaultURLs()
            XCTFail("expected vaultURLs() to throw for a custom root")
        } catch let error as LibraryRootError {
            XCTAssertEqual(error, .encryptedLibrary)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSetRootBumpsTheGeneration() async {
        let container = makeContainer()
        let first = await container.rootGeneration
        let second = await container.setRoot(.custom(tempRoot))
        XCTAssertGreaterThan(second, first)
        let third = await container.setRoot(.iCloud)
        XCTAssertGreaterThan(third, second)
    }

    func testSetRootClearsTheCachedDirectory() async throws {
        let container = makeContainer()
        let other = tempRoot.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        await container.setRoot(.custom(tempRoot))
        _ = try await container.itemsDirectory()
        await container.setRoot(.custom(other))
        let resolved = try await container.itemsDirectory()

        XCTAssertEqual(resolved.standardizedFileURL, other.standardizedFileURL)
    }

    func testCustomRootIsNotICloudBacked() async throws {
        let container = makeContainer()
        await container.setRoot(.custom(tempRoot))
        _ = try await container.itemsDirectory()
        let backed = await container.isICloudBacked
        XCTAssertFalse(backed)
    }

    func testResolveReturnsTheDirectoryPairedWithItsGeneration() async throws {
        let container = makeContainer()
        let generation = await container.setRoot(.custom(tempRoot))
        let resolved = try await container.resolveItemsDirectory()

        XCTAssertEqual(resolved.url.standardizedFileURL, tempRoot.standardizedFileURL)
        XCTAssertEqual(resolved.generation, generation)
    }

    func testResolvedGenerationTracksLaterSwitches() async throws {
        let container = makeContainer()
        let other = tempRoot.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        await container.setRoot(.custom(tempRoot))
        let first = try await container.resolveItemsDirectory()
        await container.setRoot(.custom(other))
        let second = try await container.resolveItemsDirectory()

        XCTAssertNotEqual(first.generation, second.generation,
                          "a switch must make the earlier pairing detectably stale")
        XCTAssertEqual(second.url.standardizedFileURL, other.standardizedFileURL)
    }

    func testCachedCustomRootIsRecheckedAfterItDisappears() async throws {
        let container = makeContainer()
        let folder = tempRoot.appendingPathComponent("ejectable", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await container.setRoot(.custom(folder))
        _ = try await container.itemsDirectory()

        try FileManager.default.removeItem(at: folder)

        do {
            _ = try await container.itemsDirectory()
            XCTFail("a cached custom root must not be handed back after it disappears")
        } catch let error as LibraryRootError {
            XCTAssertEqual(error, .unavailable(folder))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "the re-check must not recreate the folder")
    }

    func testRootIsRestoredFromPersistence() async {
        let defaults = UserDefaults(suiteName: "LibraryContainerRootTests-restore")!
        defaults.removePersistentDomain(forName: "LibraryContainerRootTests-restore")
        let rootStore = LibraryRootStore(defaults: defaults)
        rootStore.save(.custom(tempRoot))

        let container = LibraryContainer(rootStore: rootStore)
        let root = await container.root
        XCTAssertEqual(root, .custom(tempRoot))
    }
}
