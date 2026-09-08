import XCTest
@testable import Diffusely

final class LibraryVaultProviderRootGateTests: XCTestCase {
    private typealias Provider = LibraryVaultProvider

    func testSwitchingRootOutranksEverything() {
        let gate = Provider.computedGate(
            rootOverride: .switchingRoot,
            migrationPhase: .encrypting(done: 1, total: 10),
            isPlaintextRoot: false,
            vaultState: .locked,
            pendingPlaintextCount: 5
        )
        XCTAssertEqual(gate, .switchingRoot)
    }

    func testRootUnavailableOutranksEverything() {
        let url = URL(fileURLWithPath: "/Volumes/Gone/Library")
        let gate = Provider.computedGate(
            rootOverride: .rootUnavailable(url),
            migrationPhase: .encrypting(done: 1, total: 10),
            isPlaintextRoot: false,
            vaultState: .locked,
            pendingPlaintextCount: 5
        )
        XCTAssertEqual(gate, .rootUnavailable(url))
    }

    /// A custom root is unconditionally plaintext: there is no vault to consult,
    /// so it must browse immediately rather than failing closed on `nil`.
    func testPlaintextRootIsBrowsableWithNoVault() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: true,
            vaultState: nil,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .browsable)
    }

    func testUnresolvedICloudVaultStillFailsClosed() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: false,
            vaultState: nil,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .loading)
    }

    func testMigrationStillBeatsVaultState() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .encrypting(done: 2, total: 9),
            isPlaintextRoot: false,
            vaultState: .unlocked,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .migrating)
    }

    func testLockedICloudVaultStillLocks() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: false,
            vaultState: .locked,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .locked)
    }

    func testUnlockedWithPendingPlaintextIsSetupIncomplete() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: false,
            vaultState: .unlocked,
            pendingPlaintextCount: 3
        )
        XCTAssertEqual(gate, .setupIncomplete)
    }

    func testNeitherNewGateAllowsAnAutonomousReconcile() {
        XCTAssertFalse(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .switchingRoot))
        XCTAssertFalse(LibraryStore.shouldAutonomousReconcile(
            givenLibraryGate: .rootUnavailable(URL(fileURLWithPath: "/tmp/x"))))
    }
}
