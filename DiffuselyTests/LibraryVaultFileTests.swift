import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryVaultFileTests: XCTestCase {
    private let rounds: UInt32 = 1000   // fast for tests

    func testUnlockWithPasswordAndRecoveryYieldSameDEK() throws {
        let (file, dek, recovery) = try LibraryVaultCrypto.create(password: "correct horse", rounds: rounds)
        let raw = dek.withUnsafeBytes { Data($0) }
        XCTAssertEqual(try LibraryVaultCrypto.unlock(file, password: "correct horse").withUnsafeBytes { Data($0) }, raw)
        XCTAssertEqual(try LibraryVaultCrypto.unlock(file, recoveryKey: recovery).withUnsafeBytes { Data($0) }, raw)
    }

    func testWrongPasswordRejected() throws {
        let (file, _, _) = try LibraryVaultCrypto.create(password: "right", rounds: rounds)
        XCTAssertThrowsError(try LibraryVaultCrypto.unlock(file, password: "wrong")) { error in
            XCTAssertEqual(error as? LibraryVaultError, .wrongCredential)
        }
    }

    func testPasswordChangeKeepsDEKAndInvalidatesOldPassword() throws {
        let (file, dek, _) = try LibraryVaultCrypto.create(password: "old", rounds: rounds)
        let rewrapped = try LibraryVaultCrypto.rewrapPassword(file, dek: dek, newPassword: "new")
        XCTAssertEqual(try LibraryVaultCrypto.unlock(rewrapped, password: "new").withUnsafeBytes { Data($0) },
                       dek.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try LibraryVaultCrypto.unlock(rewrapped, password: "old"))
    }

    func testVaultFileCodableRoundTrips() throws {
        let (file, _, _) = try LibraryVaultCrypto.create(password: "p", rounds: rounds)
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(LibraryVaultFile.self, from: data)
        XCTAssertEqual(decoded, file)
    }

    func testCrockfordBase32RoundTrips() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let original = Data(bytes)
        let encoded = CrockfordBase32.encodeGrouped(original)
        let decoded = CrockfordBase32.decodeGrouped(encoded)
        XCTAssertEqual(decoded, original)
    }
}
