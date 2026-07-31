import XCTest
@testable import Diffusely

final class LibraryVaultTests: XCTestCase {
    private func makeVault() -> (LibraryVault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(
            vaultURL: dir.appendingPathComponent("vault.json"),
            backupURL: dir.appendingPathComponent("vault.backup.json"),
            keyStore: InMemoryKeyStore(), rounds: 1000
        )
        return (vault, dir)
    }

    func testLifecycle() async throws {
        let (vault, _) = makeVault()
        let s0 = await vault.state()
        XCTAssertEqual(s0, .notConfigured)

        let recovery = try await vault.configure(password: "pw")
        XCTAssertFalse(recovery.isEmpty)
        let s1 = await vault.state()
        XCTAssertEqual(s1, .unlocked)
        let c1 = await vault.crypto()
        XCTAssertNotNil(c1)

        await vault.lock()
        let s2 = await vault.state()
        XCTAssertEqual(s2, .locked)
        let c2 = await vault.crypto()
        XCTAssertNil(c2)

        try await vault.unlock(password: "pw")
        let s3 = await vault.state()
        XCTAssertEqual(s3, .unlocked)

        await vault.lock()
        try await vault.unlock(recoveryKey: recovery)
        let s4 = await vault.state()
        XCTAssertEqual(s4, .unlocked)
    }

    func testWrongPasswordThrowsAndStaysLocked() async throws {
        let (vault, _) = makeVault()
        _ = try await vault.configure(password: "pw")
        await vault.lock()
        do { try await vault.unlock(password: "nope"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? LibraryVaultError, .wrongCredential) }
        let s = await vault.state()
        XCTAssertEqual(s, .locked)
    }

    func testConfigurePersistsVaultAcrossInstances() async throws {
        let (vault, dir) = makeVault()
        _ = try await vault.configure(password: "pw")
        // Second instance over the same directory sees a configured, locked vault.
        let reopened = LibraryVault(
            vaultURL: dir.appendingPathComponent("vault.json"),
            backupURL: dir.appendingPathComponent("vault.backup.json"),
            keyStore: InMemoryKeyStore(), rounds: 1000
        )
        let s = await reopened.state()
        XCTAssertEqual(s, .locked)
        try await reopened.unlock(password: "pw")
        let s2 = await reopened.state()
        XCTAssertEqual(s2, .unlocked)
    }

    func testCorruptVaultFileReadsAsLockedNotNotConfigured() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vaultURL = dir.appendingPathComponent("vault.json")
        let backupURL = dir.appendingPathComponent("vault.backup.json")
        // Both primary and backup exist on disk but fail to decode as a LibraryVaultFile.
        try Data("not json".utf8).write(to: vaultURL)
        try Data("also not json".utf8).write(to: backupURL)

        let vault = LibraryVault(vaultURL: vaultURL, backupURL: backupURL, keyStore: InMemoryKeyStore(), rounds: 1000)
        let s = await vault.state()
        XCTAssertEqual(s, .locked)
    }

    /// `snapshot()` must return a (state, crypto) pair that always agrees —
    /// it's what closes the TOCTOU gap in `LibraryIndexService.reconcile`
    /// where reading `state()` and `crypto()` as two separate awaits could
    /// observe a lock() that happened in between (`.unlocked` state paired
    /// with `nil` crypto from the second call, or vice versa).
    func testSnapshotReturnsConsistentStateAndCrypto() async throws {
        let (vault, _) = makeVault()

        let s0 = await vault.snapshot()
        XCTAssertEqual(s0.state, .notConfigured)
        XCTAssertNil(s0.crypto)

        _ = try await vault.configure(password: "pw")
        let s1 = await vault.snapshot()
        XCTAssertEqual(s1.state, .unlocked)
        XCTAssertNotNil(s1.crypto)

        await vault.lock()
        let s2 = await vault.snapshot()
        XCTAssertEqual(s2.state, .locked)
        XCTAssertNil(s2.crypto)

        try await vault.unlock(password: "pw")
        let s3 = await vault.snapshot()
        XCTAssertEqual(s3.state, .unlocked)
        XCTAssertNotNil(s3.crypto)
    }

    /// Exercises `changePassword`'s bridge to the dedicated KDF queue: the old
    /// password must unwrap the DEK and the new password must be able to
    /// unlock afterward, while the old password no longer works.
    func testChangePasswordRoundTripsThroughKDFBridge() async throws {
        let (vault, _) = makeVault()
        _ = try await vault.configure(password: "old-pw")
        try await vault.changePassword(old: "old-pw", new: "new-pw")

        await vault.lock()
        try await vault.unlock(password: "new-pw")
        let s = await vault.state()
        XCTAssertEqual(s, .unlocked)

        await vault.lock()
        do { try await vault.unlock(password: "old-pw"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? LibraryVaultError, .wrongCredential) }
    }

    func testConfigureRefusesToOverwriteExistingVault() async throws {
        let (vault, dir) = makeVault()
        _ = try await vault.configure(password: "pw")
        let vaultURL = dir.appendingPathComponent("vault.json")
        let before = try Data(contentsOf: vaultURL)

        // A second instance over the same directory must refuse to clobber the existing vault.
        let reopened = LibraryVault(
            vaultURL: vaultURL,
            backupURL: dir.appendingPathComponent("vault.backup.json"),
            keyStore: InMemoryKeyStore(), rounds: 1000
        )
        do {
            _ = try await reopened.configure(password: "different")
            XCTFail("expected configure to throw on an already-configured vault")
        } catch {
            XCTAssertEqual(error as? LibraryVaultError, .malformed)
        }
        let after = try Data(contentsOf: vaultURL)
        XCTAssertEqual(before, after)
    }
}
