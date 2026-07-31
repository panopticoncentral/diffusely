import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryImageRequestEncryptedTests: XCTestCase {
    func testDecryptedMediaDataReadsEncryptedBlob() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])   // stub bytes
        try store.writeMedia(jpeg, itemID: 3, plaintextExtension: "jpeg")
        XCTAssertEqual(LibraryImageRequest.decryptedMediaData(itemID: 3, store: store), jpeg)
    }
}
