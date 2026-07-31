import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryKDFTests: XCTestCase {
    func testPBKDF2IsDeterministicAndSaltSensitive() {
        let salt = Data([0x01, 0x02, 0x03, 0x04])
        let a = LibraryKDF.pbkdf2SHA256(password: "hunter2", salt: salt, rounds: 1000, keyByteCount: 32)
        let b = LibraryKDF.pbkdf2SHA256(password: "hunter2", salt: salt, rounds: 1000, keyByteCount: 32)
        let other = LibraryKDF.pbkdf2SHA256(password: "hunter2", salt: Data([0x09]), rounds: 1000, keyByteCount: 32)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, other)
    }

    func testHexIsLowercaseAndFullWidth() {
        XCTAssertEqual(LibraryKDF.hex(Data([0x00, 0x0f, 0xff])), "000fff")
    }

    func testHKDFSubkeysDifferByInfo() {
        let master = SymmetricKey(size: .bits256)
        let content = LibraryKDF.hkdfSubkey(from: master, salt: Data(), info: "content", byteCount: 32)
        let file = LibraryKDF.hkdfSubkey(from: master, salt: Data(), info: "filename", byteCount: 32)
        XCTAssertNotEqual(content.withUnsafeBytes { Data($0) }, file.withUnsafeBytes { Data($0) })
    }

    func testPBKDF2DataOverloadMatchesStringOverloadForUTF8Password() {
        let salt = Data([0xAA, 0xBB, 0xCC])
        let fromString = LibraryKDF.pbkdf2SHA256(password: "abc", salt: salt, rounds: 1000, keyByteCount: 32)
        let fromData = LibraryKDF.pbkdf2SHA256(passwordData: Data("abc".utf8), salt: salt, rounds: 1000, keyByteCount: 32)
        XCTAssertEqual(fromString, fromData)
    }
}
