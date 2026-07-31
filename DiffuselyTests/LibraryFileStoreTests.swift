import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryFileStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testPlaintextPassthroughUsesLegacyNames() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(Data("{\"itemID\":5}".utf8), itemID: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("5.json").path))
        XCTAssertEqual(store.readMetadata(itemID: 5), Data("{\"itemID\":5}".utf8))
        XCTAssertFalse(store.isEncrypted)
    }

    func testEncryptedWriteIsOpaqueAndRoundTrips() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        // Multi-digit id: collision probability for a 6-digit run appearing
        // by chance in a 32-hex-char token is negligible (unlike testing for
        // a single digit, which is ~87% likely to appear by chance and made
        // this flaky before — see LibraryFileCryptoTests.testFileNameRevealsNoItemID
        // for the same pattern).
        let itemID = 424242
        let payload = Data("{\"itemID\":\(itemID)}".utf8)
        try store.writeMetadata(payload, itemID: itemID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(itemID).json").path))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".m") })
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains("\(itemID)") })   // id not in name
        XCTAssertEqual(store.readMetadata(itemID: itemID), payload)
    }

    func testEncryptedMediaWriteIsOpaqueAndRoundTrips() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let itemID = 424242
        let media = Data("fake-media-bytes".utf8)
        try store.writeMedia(media, itemID: itemID, plaintextExtension: "jpeg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(itemID).jpeg").path))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".b") })
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains("\(itemID)") })   // id not in name
        XCTAssertEqual(store.readMedia(itemID: itemID, plaintextExtension: "jpeg"), media)
    }

    func testEnumerateAndRecoverItemID() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        try store.writeMetadata(Data("{\"itemID\":42}".utf8), itemID: 42)
        let metas = store.enumerateMetadataFiles()
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(store.itemID(forMetadataFile: metas[0]), 42)
    }

    // MARK: Aux (non-item container files)

    func testEncryptedAuxWriteIsOpaqueAndRoundTrips() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let name = "sort-assistant-state"
        let payload = Data("{\"state\":true}".utf8)
        try store.writeAux(payload, name: name)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".x") })
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains(name) })
        XCTAssertEqual(store.readAux(name: name), payload)
    }

    func testPlaintextAuxIsLiteralNamePassthrough() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let name = "album-ABC.json"
        let payload = Data("{\"albumID\":\"ABC\"}".utf8)
        try store.writeAux(payload, name: name)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        XCTAssertEqual(store.readAux(name: name), payload)
        XCTAssertEqual(store.enumerateAuxFiles(), [])
    }

    // MARK: removeAux — coordinated delete of a logical aux file (album,
    // sort-assistant state), mirroring writeAux/readAux's name resolution.

    func testRemoveAuxDeletesPlaintextLiteralFile() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let name = "album-ABC.json"
        try store.writeAux(Data("x".utf8), name: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))

        store.removeAux(name: name)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        XCTAssertNil(store.readAux(name: name))
    }

    func testRemoveAuxDeletesEncryptedOpaqueFile() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let name = "album-\(UUID().uuidString)"
        try store.writeAux(Data("x".utf8), name: name)
        XCTAssertNotNil(store.readAux(name: name))

        store.removeAux(name: name)

        XCTAssertNil(store.readAux(name: name))
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRemoveAuxOnMissingFileIsANoop() {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        store.removeAux(name: "never-written.json")   // must not throw/crash
    }

    func testDifferentAuxNamesProduceDifferentOpaqueTokens() throws {
        let dir = tempDir()
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeAux(Data("one".utf8), name: "sort-assistant-state")
        try store.writeAux(Data("two".utf8), name: "album-ABC")

        let files = store.enumerateAuxFiles()
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files.map { $0.lastPathComponent }).count, 2)
        XCTAssertEqual(store.readAux(name: "sort-assistant-state"), Data("one".utf8))
        XCTAssertEqual(store.readAux(name: "album-ABC"), Data("two".utf8))
    }

    // MARK: readAux(at:) — recovers the token from an enumerated URL directly,
    // for a caller (reconcile) that only has the opaque file and doesn't
    // already know which logical name produced it.

    func testReadAuxAtURLRecoversTokenFromFilenameStem() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        try store.writeAux(Data("hello".utf8), name: "album-\(UUID().uuidString)")

        let files = store.enumerateAuxFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(store.readAux(at: files[0]), Data("hello".utf8))
    }

    func testReadAuxAtURLReturnsNilForPlaintextStore() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let url = dir.appendingPathComponent("whatever.x")
        try Data("x".utf8).write(to: url)
        XCTAssertNil(store.readAux(at: url))
    }

    // MARK: isMetadataFileName / isAuxFileName — the suffix predicates a scan
    // that already holds a directory listing classifies names against,
    // without a second `contentsOfDirectory` walk.

    func testIsMetadataFileNameMatchesModeSpecificSuffix() {
        let plain = LibraryFileStore(itemsDirectory: tempDir(), crypto: nil)
        XCTAssertTrue(plain.isMetadataFileName("42.json"))
        XCTAssertFalse(plain.isMetadataFileName("42.jpeg"))
        XCTAssertFalse(plain.isMetadataFileName("abc123.m"))

        let encrypted = LibraryFileStore(itemsDirectory: tempDir(), crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        XCTAssertTrue(encrypted.isMetadataFileName("abc123.m"))
        XCTAssertFalse(encrypted.isMetadataFileName("42.json"))
    }

    func testIsAuxFileNameOnlyMatchesInEncryptedMode() {
        let plain = LibraryFileStore(itemsDirectory: tempDir(), crypto: nil)
        XCTAssertFalse(plain.isAuxFileName("abc123.x"))

        let encrypted = LibraryFileStore(itemsDirectory: tempDir(), crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        XCTAssertTrue(encrypted.isAuxFileName("abc123.x"))
        XCTAssertFalse(encrypted.isAuxFileName("abc123.m"))
    }

    // MARK: readMediaAsync / readMetadataAsync — the dedicated-queue bridge
    // BE-e's view-layer call sites use so the coordinated read + (encrypted)
    // AES-GCM decrypt never runs on the cooperative pool. Must return exactly
    // what the synchronous reads return, for both plaintext and encrypted.

    func testReadMediaAsyncMatchesSyncReadWhenPlaintext() async throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let itemID = 7
        let media = Data("plaintext-media-bytes".utf8)
        try store.writeMedia(media, itemID: itemID, plaintextExtension: "jpeg")

        let synced = store.readMedia(itemID: itemID, plaintextExtension: "jpeg")
        let asynced = await store.readMediaAsync(itemID: itemID, plaintextExtension: "jpeg")
        XCTAssertEqual(asynced, synced)
        XCTAssertEqual(asynced, media)
    }

    func testReadMediaAsyncMatchesSyncReadWhenEncrypted() async throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let itemID = 424242
        let media = Data("encrypted-media-bytes".utf8)
        try store.writeMedia(media, itemID: itemID, plaintextExtension: "jpeg")

        let synced = store.readMedia(itemID: itemID, plaintextExtension: "jpeg")
        let asynced = await store.readMediaAsync(itemID: itemID, plaintextExtension: "jpeg")
        XCTAssertEqual(asynced, synced)
        XCTAssertEqual(asynced, media)
    }

    func testReadMetadataAsyncMatchesSyncReadWhenPlaintext() async throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let itemID = 9
        let payload = Data("{\"itemID\":9}".utf8)
        try store.writeMetadata(payload, itemID: itemID)

        let synced = store.readMetadata(itemID: itemID)
        let asynced = await store.readMetadataAsync(itemID: itemID)
        XCTAssertEqual(asynced, synced)
        XCTAssertEqual(asynced, payload)
    }

    func testReadMetadataAsyncMatchesSyncReadWhenEncrypted() async throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let itemID = 424242
        let payload = Data("{\"itemID\":\(itemID)}".utf8)
        try store.writeMetadata(payload, itemID: itemID)

        let synced = store.readMetadata(itemID: itemID)
        let asynced = await store.readMetadataAsync(itemID: itemID)
        XCTAssertEqual(asynced, synced)
        XCTAssertEqual(asynced, payload)
    }

    func testReadMediaAsyncReturnsNilForMissingItem() async {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let result = await store.readMediaAsync(itemID: 999, plaintextExtension: "jpeg")
        XCTAssertNil(result)
    }
}
