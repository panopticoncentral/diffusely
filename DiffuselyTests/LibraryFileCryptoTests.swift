import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryFileCryptoTests: XCTestCase {
    private let dek = SymmetricKey(size: .bits256)

    func testSealOpenRoundTrips() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 42, role: .meta)
        let plaintext = Data("hello library".utf8)
        let sealed = try crypto.seal(plaintext, fileToken: token)
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(try crypto.open(sealed, fileToken: token), plaintext)
    }

    func testTamperIsDetected() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 7, role: .media)
        var sealed = try crypto.seal(Data("x".utf8), fileToken: token)
        sealed[sealed.count - 1] ^= 0xFF   // flip a tag byte
        XCTAssertThrowsError(try crypto.open(sealed, fileToken: token))
    }

    func testWrongTokenFailsToOpen() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let sealed = try crypto.seal(Data("x".utf8), fileToken: crypto.fileToken(itemID: 1, role: .meta))
        XCTAssertThrowsError(try crypto.open(sealed, fileToken: crypto.fileToken(itemID: 2, role: .meta)))
    }

    func testFileNamesAreDeterministicRoleDistinctAndSuffixed() {
        let crypto = LibraryFileCrypto(dek: dek)
        XCTAssertEqual(crypto.fileName(itemID: 42, role: .meta), crypto.fileName(itemID: 42, role: .meta))
        XCTAssertTrue(crypto.fileName(itemID: 42, role: .meta).hasSuffix(".m"))
        XCTAssertTrue(crypto.fileName(itemID: 42, role: .media).hasSuffix(".b"))
        XCTAssertNotEqual(crypto.fileName(itemID: 42, role: .meta).dropLast(2),
                          crypto.fileName(itemID: 42, role: .media).dropLast(2))
    }

    func testFileNameRevealsNoItemID() {
        let crypto = LibraryFileCrypto(dek: dek)
        XCTAssertFalse(crypto.fileName(itemID: 123456, role: .meta).contains("123456"))
    }

    func testOpenRejectsEmptyEnvelope() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 1, role: .meta)
        do {
            _ = try crypto.open(Data(), fileToken: token)
            XCTFail("Expected LibraryCryptoError.badEnvelope")
        } catch LibraryCryptoError.badEnvelope {
            // expected
        } catch {
            XCTFail("Expected LibraryCryptoError.badEnvelope, got \(error)")
        }
    }

    func testOpenRejectsWrongMagicBytes() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 2, role: .meta)
        let malformed = Data("XXXX".utf8) + Data([1, 2, 3])
        do {
            _ = try crypto.open(malformed, fileToken: token)
            XCTFail("Expected LibraryCryptoError.badEnvelope")
        } catch LibraryCryptoError.badEnvelope {
            // expected
        } catch {
            XCTFail("Expected LibraryCryptoError.badEnvelope, got \(error)")
        }
    }

    func testOpenRejectsTooShortEnvelope() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 3, role: .meta)
        let tooShort = Data("DFEB".utf8) + Data([1])   // 5 bytes total, fewer than 6
        do {
            _ = try crypto.open(tooShort, fileToken: token)
            XCTFail("Expected LibraryCryptoError.badEnvelope")
        } catch LibraryCryptoError.badEnvelope {
            // expected
        } catch {
            XCTFail("Expected LibraryCryptoError.badEnvelope, got \(error)")
        }
    }
}
