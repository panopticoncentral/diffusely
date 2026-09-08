import XCTest
@testable import Diffusely

final class LibraryFolderWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFolderWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFiresWhenAFileIsAdded() throws {
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = LibraryFolderWatcher(url: folder) { fired.fulfill() }
        XCTAssertNotNil(watcher)
        defer { watcher?.cancel() }

        try Data("{}".utf8).write(to: folder.appendingPathComponent("1.json"))
        wait(for: [fired], timeout: 5)
    }

    func testFiresWhenAFileIsRemoved() throws {
        let file = folder.appendingPathComponent("2.json")
        try Data("{}".utf8).write(to: file)

        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = LibraryFolderWatcher(url: folder) { fired.fulfill() }
        defer { watcher?.cancel() }

        try FileManager.default.removeItem(at: file)
        wait(for: [fired], timeout: 5)
    }

    func testDoesNotFireAfterCancel() throws {
        let fired = expectation(description: "watcher fired")
        fired.isInverted = true
        let watcher = LibraryFolderWatcher(url: folder) { fired.fulfill() }
        watcher?.cancel()

        try Data("{}".utf8).write(to: folder.appendingPathComponent("3.json"))
        wait(for: [fired], timeout: 2)
    }

    func testFiresWhenTheWatchedFolderItselfIsRemoved() throws {
        let doomed = folder.appendingPathComponent("doomed", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)

        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = LibraryFolderWatcher(url: doomed) { fired.fulfill() }
        XCTAssertNotNil(watcher)
        defer { watcher?.cancel() }

        try FileManager.default.removeItem(at: doomed)
        wait(for: [fired], timeout: 5)
    }

    func testReturnsNilForAMissingFolder() {
        let missing = folder.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(LibraryFolderWatcher(url: missing) { })
    }
}
