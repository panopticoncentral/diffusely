import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryFileWriterEncryptedTests: XCTestCase {
    private func meta(_ id: Int) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: id,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(id)", sourceDomain: "civitai.com",
            originalCDNURL: "https://cdn/\(id).jpeg", mediaType: .image,
            mediaFileName: "\(id).jpeg", fileByteSize: 3, contentSHA256: "abc",
            width: 1, height: 1, nsfwLevel: 1, author: .init(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil, savedAt: Date(), savedByAppVersion: "test")
    }

    func testCommitThenReadUnderEncryptionRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let writer = LibraryFileWriter(store: store)

        let tmp = dir.appendingPathComponent("incoming.bin")
        try Data("img".utf8).write(to: tmp)
        try writer.commit(metadata: meta(9), mediaTempURL: tmp)

        XCTAssertTrue(writer.itemExists(itemID: 9))
        XCTAssertEqual(writer.readMetadata(itemID: 9)?.itemID, 9)
        // No plaintext id-named files leaked to disk.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains("9.json"))
        XCTAssertFalse(names.contains("9.jpeg"))
    }
}
