import XCTest
@testable import Diffusely

final class LibraryRootStoreTests: XCTestCase {
    private var tempRoot: URL!
    private let store = LibraryRootStore(defaults: UserDefaults(suiteName: "LibraryRootStoreTests")!)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRootStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, into folder: URL) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    func testEmptyFolderIsValid() throws {
        let folder = try makeFolder("empty")
        XCTAssertNil(store.validate(folder, iCloudItemsDirectory: nil))
    }

    func testFolderWithPlaintextLibraryIsValid() throws {
        let folder = try makeFolder("library")
        try write("12345.json", into: folder)
        try write("12345.jpeg", into: folder)
        try write("album-\(UUID().uuidString).json", into: folder)
        XCTAssertNil(store.validate(folder, iCloudItemsDirectory: nil))
    }

    func testMissingFolderIsNotADirectory() {
        let missing = tempRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(store.validate(missing, iCloudItemsDirectory: nil), .notADirectory)
    }

    func testFileIsNotADirectory() throws {
        try write("plain.txt", into: tempRoot)
        XCTAssertEqual(store.validate(tempRoot.appendingPathComponent("plain.txt"),
                                      iCloudItemsDirectory: nil), .notADirectory)
    }

    func testFolderWithVaultFileIsRejected() throws {
        let folder = try makeFolder("vaulted")
        try write("vault.json", into: folder)
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .encryptedLibrary)
    }

    func testFolderWithSealedFilesIsRejected() throws {
        for (name, ext) in [("meta", "m"), ("media", "b"), ("aux", "x")] {
            let folder = try makeFolder("sealed-\(name)")
            try write("a1b2c3.\(ext)", into: folder)
            XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .encryptedLibrary,
                           "a .\(ext) file should mark the folder encrypted")
        }
    }

    func testICloudContainerIsRejected() throws {
        let folder = try makeFolder("container")
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: folder), .isICloudContainer)
    }

    func testNotWritableFolderIsRejected() throws {
        let folder = try makeFolder("readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .notWritable)
    }

    func testUnreadableFolderIsRejected() throws {
        let folder = try makeFolder("unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .unreadable)
    }
}
