import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryTempMediaTests: XCTestCase {
    func testWriteIsOutsideContainerAndSweepable() throws {
        let url = try LibraryTempMedia.writePlaintext(Data("clip".utf8), itemID: 11, ext: "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(url.path.contains("Mobile Documents"))   // not in iCloud container
        LibraryTempMedia.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: materialize — the decrypt-to-temp orchestration shared by the
    // view-layer sites that need a real file URL for encrypted media (Quick
    // Look, drag-out).

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMaterializeDecryptsIntoASweepableTempFile() async throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let itemID = 909_090
        let media = Data("fake-encrypted-media-bytes".utf8)
        try store.writeMedia(media, itemID: itemID, plaintextExtension: "jpeg")

        let tempURL = await LibraryTempMedia.materialize(store: store, itemID: itemID, plaintextExtension: "jpeg")
        let url = try XCTUnwrap(tempURL)

        XCTAssertEqual(try Data(contentsOf: url), media)
        XCTAssertFalse(url.path.contains("Mobile Documents"))   // not in iCloud container — ephemeral Caches only
        // The on-disk encrypted original is untouched by materializing a copy.
        XCTAssertEqual(store.readMedia(itemID: itemID, plaintextExtension: "jpeg"), media)

        LibraryTempMedia.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMaterializeReturnsNilWhenEncryptedMediaIsMissing() async {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))

        let tempURL = await LibraryTempMedia.materialize(store: store, itemID: 4, plaintextExtension: "jpeg")

        XCTAssertNil(tempURL)
    }
}
