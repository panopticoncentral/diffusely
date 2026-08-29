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

/// The companion to the gate above: once the gate STOPS blocking, something
/// has to actually run the reconcile it blocked.
///
/// `LibraryStore.start()` is called twice in the encrypted-vault flow — at
/// launch by `ContentView.startLibrarySubsystem` (deliberately before any
/// unlock, so the locked-skip engages) and again by `LibraryView`'s
/// `.task(id: libraryGate)` once the gate reaches `.browsable`. The launch call
/// used to set `isReady` even though its reconcile had been skipped, so
/// `start()`'s `guard !isReady` swallowed the second call and no catch-up
/// reconcile ever ran after an unlock. That left the `NSMetadataQuery` change
/// handler as the only live trigger, and it only fires on a container change
/// landing while this device is open AND unlocked — which a device the user
/// saves from produces constantly, but a read-only device (the iPhone here)
/// never does. Its index stayed frozen for days while the iPad and Mac synced
/// normally; Settings → "Rebuild Index" was no help because it is disabled
/// while non-`.browsable` too.
///
/// Proven against the pure decision, mirroring the suites either side of it.
@Suite struct LibraryStoreStartReconcileTests {
    /// Cold launch: nothing has run yet, so `start()` reconciles.
    @Test func coldStartReconciles() {
        #expect(LibraryStore.shouldStartReconcile(
            isReady: false, didReconcileSinceLaunch: false) == true)
    }

    /// THE REGRESSION: the launch `start()` completed (`isReady`) but its
    /// reconcile was skipped by the `.locked` gate, so the post-unlock
    /// `start()` MUST still reconcile. `isReady` alone reports "already
    /// started" here and wrongly suppressed it.
    @Test func startAfterUnlockReconcilesWhenLaunchReconcileWasSkipped() {
        #expect(LibraryStore.shouldStartReconcile(
            isReady: true, didReconcileSinceLaunch: false) == true)
    }

    /// A reconcile has actually run, so repeat `start()` calls (every later
    /// `libraryGate` transition re-fires `LibraryView`'s `.task`) stay the
    /// cheap no-op they were designed to be.
    @Test func repeatStartIsANoOpOnceAReconcileHasRun() {
        #expect(LibraryStore.shouldStartReconcile(
            isReady: true, didReconcileSinceLaunch: true) == false)
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

/// The bug this closes: `didReconcileSinceLaunch` latched for the lifetime of
/// the PROCESS, but iOS keeps that process alive for days. The idle auto-lock
/// (`DiffuselyApp`, 300s) re-locks the vault every time the app sits in the
/// background, so the real cycle on a read-only device is
/// `.browsable` → `.locked` → `.browsable`, over and over, inside one process.
///
/// Two things then compound. `reconcileNow` drops any `NSMetadataQuery` change
/// that lands while the gate is non-`.browsable` (the locked-skip), and
/// `NSMetadataQuery` never re-delivers it. The post-unlock `start()` that
/// should have caught up was itself suppressed, because a reconcile HAD run
/// earlier in the process. Net effect: every iCloud arrival landing while the
/// Library was locked was lost until the process was killed — the iPhone sat
/// five days behind the Mac and iPad, and only a force-quit brought it current.
///
/// So the latch must be scoped to "since the gate last became `.browsable`",
/// not "since launch": leaving `.browsable` clears it, so the next unlock is
/// guaranteed a catch-up reconcile.
@Suite struct LibraryStoreReconcileLatchScopeTests {
    /// Leaving `.browsable` (idle auto-lock while backgrounded) must clear the
    /// latch — that is what re-arms the post-unlock catch-up.
    @Test func leavingBrowsableClearsTheLatch() {
        #expect(LibraryStore.reconcileLatch(
            afterGateChangedTo: .locked, currentlyLatched: true) == false)
    }

    /// A transition that does NOT leave `.browsable` must not clear a latch
    /// that is already set, or every gate republish would re-reconcile.
    @Test func stayingBrowsablePreservesTheLatch() {
        #expect(LibraryStore.reconcileLatch(
            afterGateChangedTo: .browsable, currentlyLatched: true) == true)
    }

    /// THE REGRESSION, end to end: a reconcile ran, the vault auto-locked in
    /// the background, the user unlocked again. `LibraryView`'s
    /// `.task(id: libraryGate)` re-fires `start()`, which MUST reconcile to
    /// pick up everything that synced in while the Library was locked.
    @Test func startAfterRelockAndUnlockReconcilesAgain() {
        var latched = true    // a reconcile ran earlier this process
        latched = LibraryStore.reconcileLatch(
            afterGateChangedTo: .locked, currentlyLatched: latched)
        latched = LibraryStore.reconcileLatch(
            afterGateChangedTo: .browsable, currentlyLatched: latched)

        #expect(LibraryStore.shouldStartReconcile(
            isReady: true, didReconcileSinceLaunch: latched) == true)
    }
}
