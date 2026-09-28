import XCTest
@testable import Diffusely

final class LibraryVaultProviderRootGateTests: XCTestCase {
    private typealias Provider = LibraryVaultProvider

    func testSwitchingRootOutranksEverything() {
        let gate = Provider.computedGate(
            rootOverride: .switchingRoot,
            migrationPhase: .encrypting(done: 1, total: 10),
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
            vaultState: .locked,
            pendingPlaintextCount: 5
        )
        XCTAssertEqual(gate, .rootUnavailable(url))
    }

    func testUnconfiguredVaultIsBrowsable() {
        let gate = Provider.computedGate(rootOverride: nil, migrationPhase: .idle,
            vaultState: .notConfigured, pendingPlaintextCount: 0)
        XCTAssertEqual(gate, .browsable)
    }

    func testUnresolvedICloudVaultStillFailsClosed() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            vaultState: nil,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .loading)
    }

    func testMigrationStillBeatsVaultState() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .encrypting(done: 2, total: 9),
            vaultState: .unlocked,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .migrating)
    }

    func testLockedICloudVaultStillLocks() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            vaultState: .locked,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .locked)
    }

    func testUnlockedWithPendingPlaintextIsSetupIncomplete() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
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
