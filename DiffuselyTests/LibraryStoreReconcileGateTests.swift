import Testing
@testable import Diffusely

/// BE-f: `LibraryStore.reconcileNow()` is the sole choke point for the two
/// AUTONOMOUS reconcile entry points — the `NSMetadataQuery` change handler
/// and the launch-time `start()` reconcile — that fire on their own and
/// aren't reachable by Task 17's `LibraryView` gate. `.migrating` and
/// `.setupIncomplete` are UNLOCKED vault states (so the Task 11b
/// `LibraryIndexService.shouldReconcile` locked-only check alone lets them
/// through), but the on-disk container is still half-migrated then — an
/// autonomous reconcile firing would prune the not-yet-migrated files from
/// the index.
///
/// Proven here against the pure `LibraryStore.shouldAutonomousReconcile`
/// gate-check directly, mirroring
/// `LibraryIndexEncryptedTests.shouldReconcileBlocksOnlyLockedState`: driving
/// the real `LibraryVaultProvider.shared` singleton into these states would
/// leak global state into every other test in the process.
@Suite struct LibraryStoreReconcileGateTests {
    @Test func autonomousReconcileBlockedWhileNonBrowsable() {
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .loading) == false)
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .locked) == false)
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .migrating) == false)
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .setupIncomplete) == false)
    }

    /// `.browsable` covers both the plaintext shipping path (a
    /// `.notConfigured` vault maps straight to `.browsable` in
    /// `LibraryVaultProvider.computedGate()`) and a fully-migrated encrypted
    /// vault — both must let the autonomous reconcile run exactly as today.
    @Test func autonomousReconcileRunsWhileBrowsable() {
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .browsable) == true)
    }
}

/// Closes the last door in the "no reconcile/prune against a half-migrated
/// store" guarantee: the MANUAL Settings → "Rebuild Index" button
/// (`LibraryStore.rebuildIndex()`) is reachable any time Settings is —
/// including while `.migrating` or `.setupIncomplete` (both UNLOCKED vault
/// states) — so without a gate it would run the exact same prune-against-a
/// -half-migrated-store as the autonomous entry points BE-f closed.
///
/// `rebuildIndex()` reuses `LibraryStore.shouldAutonomousReconcile` directly
/// (the decision is identical: only `.browsable` may reconcile/rebuild
/// through `LibraryStore`), so this suite proves the same gate decision
/// again framed for the manual path, mirroring `LibraryStoreReconcileGateTests`
/// above — pure gate-check only, no async singleton.
@Suite struct LibraryStoreManualRebuildGateTests {
    @Test func manualRebuildBlockedWhileNonBrowsable() {
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .loading) == false)
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .locked) == false)
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .migrating) == false)
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .setupIncomplete) == false)
    }

    /// `.browsable` covers both the plaintext shipping path (a
    /// `.notConfigured` vault maps straight to `.browsable`) and a
    /// fully-migrated encrypted vault — the manual rebuild must proceed
    /// exactly as today in both.
    @Test func manualRebuildProceedsWhileBrowsable() {
        #expect(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .browsable) == true)
    }
}
