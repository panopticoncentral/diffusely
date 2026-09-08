import XCTest
@testable import Diffusely

@MainActor
final class LibraryVaultProviderTests: XCTestCase {
    func testFileStoreIsPassthroughWhenNotConfigured() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)
        let store = await provider.fileStore()
        XCTAssertFalse(store.isEncrypted)
    }

    func testFileStoreIsEncryptedWhenUnlocked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        _ = try await vault.configure(password: "pw")
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)
        let store = await provider.fileStore()
        XCTAssertTrue(store.isEncrypted)
    }

    /// FINDING 1's seam. `LibraryRootCoordinator.live` asks this right after
    /// `rebootstrap()` to tell "the new root's vault is locked, which is the
    /// expected result of switching back to an encrypted iCloud Library" apart
    /// from "the new root is unreadable and the index has just been wiped".
    func testIsVaultLockedReportsTheLiveVaultState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let unconfigured = await provider.isVaultLocked()
        XCTAssertFalse(unconfigured, "an unconfigured vault is not locked — it's plaintext")

        _ = try await vault.configure(password: "pw")
        let unlocked = await provider.isVaultLocked()
        XCTAssertFalse(unlocked)

        await vault.lock()
        let locked = await provider.isVaultLocked()
        XCTAssertTrue(locked, "this is the state a fresh vault over an existing vault.json reports")
    }

    // MARK: reconcileContext() — the atomic (state, store) pair reconcile's
    // locked-guard depends on. Uses the injectable provider (not `.shared`),
    // so this is safe from the singleton-pollution concern documented for
    // `LibraryIndexEncryptedTests.shouldReconcileBlocksOnlyLockedState`.

    func testReconcileContextReportsLockedWithPassthroughStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        _ = try await vault.configure(password: "pw")
        await vault.lock()
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let ctx = await provider.reconcileContext()
        XCTAssertEqual(ctx.state, .locked)
        XCTAssertFalse(ctx.store.isEncrypted, "a locked vault's store must not silently look encrypted")
    }

    func testReconcileContextReportsUnlockedWithEncryptedStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        _ = try await vault.configure(password: "pw")
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let ctx = await provider.reconcileContext()
        XCTAssertEqual(ctx.state, .unlocked)
        XCTAssertTrue(ctx.store.isEncrypted)
    }

    func testReconcileContextIsNotConfiguredBeforeAnyConfigure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let ctx = await provider.reconcileContext()
        XCTAssertEqual(ctx.state, .notConfigured)
        XCTAssertFalse(ctx.store.isEncrypted)
    }

    // MARK: - libraryGate

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeVault(_ dir: URL) -> LibraryVault {
        LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                     backupURL: dir.appendingPathComponent("v.bak.json"),
                     keyStore: InMemoryKeyStore(), rounds: 1000)
    }

    /// A full, decodable plaintext item (`<id>.json` counts toward
    /// `pendingItemsAndAuxCount()`).
    private func seedPlaintextItem(_ dir: URL, id: Int) throws {
        try Data("{\"schemaVersion\":5,\"itemID\":\(id),\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"\(id).jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}".utf8)
            .write(to: dir.appendingPathComponent("\(id).json"))
        try Data("m\(id)".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
    }

    /// The coarse gate starts `.loading` before anything resolves the vault.
    func testLibraryGateStartsLoading() async throws {
        let dir = try makeDir()
        let provider = LibraryVaultProvider(vault: makeVault(dir), itemsDirectory: dir)
        XCTAssertEqual(provider.libraryGate, .loading)
    }

    /// Encryption off (the shipping state) → `.browsable`.
    func testLibraryGateBrowsableWhenNotConfigured() async throws {
        let dir = try makeDir()
        let provider = LibraryVaultProvider(vault: makeVault(dir), itemsDirectory: dir)

        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .browsable)
    }

    /// Configured but locked → `.locked`.
    func testLibraryGateLockedWhenLocked() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")
        await vault.lock()
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .locked)
    }

    /// Configured + unlocked with plaintext still awaiting encryption (a
    /// partial/failed enable) → `.setupIncomplete`.
    func testLibraryGateSetupIncompleteWhenUnlockedWithPendingPlaintext() async throws {
        let dir = try makeDir()
        try seedPlaintextItem(dir, id: 1)
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")   // unlocked, but item 1 still plaintext
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .setupIncomplete)
    }

    /// Configured + unlocked with nothing pending → `.browsable`.
    func testLibraryGateBrowsableWhenUnlockedAndFullyMigrated() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")   // unlocked, no plaintext items in dir
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .browsable)
    }

    /// An active migration phase wins over vault state: the gate is `.migrating`
    /// even though the vault (unlocked, nothing pending) would otherwise be
    /// `.browsable`. Also confirms `onPhaseChange` mirrors into `migrationPhase`.
    func testLibraryGateMigratingWhenPhaseActive() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let coordinatorOrNil = await provider.encryptionCoordinator()
        let coordinator = try XCTUnwrap(coordinatorOrNil)
        // Drive the coordinator's phase-change hook directly (the same hook a
        // real migration fires), then force a deterministic recompute.
        coordinator.onPhaseChange?(.encrypting(done: 1, total: 3))
        XCTAssertEqual(provider.migrationPhase, .encrypting(done: 1, total: 3),
                       "onPhaseChange must mirror the phase into migrationPhase")

        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .migrating)
    }

    /// `encryptionCoordinator()` builds the coordinator once and returns the
    /// same cached instance.
    func testEncryptionCoordinatorIsCached() async throws {
        let dir = try makeDir()
        let provider = LibraryVaultProvider(vault: makeVault(dir), itemsDirectory: dir)

        let aOrNil = await provider.encryptionCoordinator()
        let bOrNil = await provider.encryptionCoordinator()
        let a = try XCTUnwrap(aOrNil)
        let b = try XCTUnwrap(bOrNil)
        XCTAssertTrue(a === b)
    }

    /// A full enable driven through the PROVIDER's own gate-aware entry points
    /// (`enableConfigure` then `runEnableMigration`), via the real cached
    /// coordinator (NOT a hand-rolled `onPhaseChange` call). The gate must be
    /// `.setupIncomplete` the instant configure returns — every file is still
    /// plaintext under a now-encrypted vault, the stale-`.browsable` exposure
    /// the provider ownership exists to prevent — then land `.browsable` once
    /// the migration completes, exercising the real `phase` didSet →
    /// `onPhaseChange` → migrating-clears-to-browsable linkage end to end.
    func testProviderEnableFlowGatesSetupIncompleteThenBrowsable() async throws {
        let dir = try makeDir()
        try seedPlaintextItem(dir, id: 1)
        let vault = makeVault(dir)
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let key = try await provider.enableConfigure(password: "pw")
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(provider.libraryGate, .setupIncomplete,
                       "gate must flag the all-plaintext window right after configure, not stay .browsable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))

        try await provider.runEnableMigration()
        XCTAssertEqual(provider.libraryGate, .browsable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path),
                       "item 1 should be encrypted after the provider-driven migration")
    }

    // MARK: - rootOverride state machine (review findings 1 & 2)
    //
    // The real resolve `Task` inside `resolveIfNeeded()` never runs in the
    // test host (see `isRunningInTestHost`), so these tests can't drive a
    // full `rebootstrap()` round-trip against a real container. Instead they
    // exercise the same state-transition helpers the production Task calls
    // (`clearRootUnavailableOnSuccessfulResolve()`, which `finishBootstrap`
    // calls on every successful resolve, and `endRootSwitch()`), using the
    // injectable initializer per the existing convention in this file.

    /// Finding 1: a stale `.rootUnavailable` override must not survive a
    /// resolve that then succeeds — otherwise a root plugged back in leaves
    /// the Library gated forever, since nothing else ever clears it.
    func testSuccessfulResolveClearsStaleRootUnavailableOverride() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")   // unlocked, no pending plaintext
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        let goneURL = URL(fileURLWithPath: "/Volumes/Gone/Library")
        provider.reportRootUnavailable(goneURL)
        XCTAssertEqual(provider.libraryGate, .rootUnavailable(goneURL))

        // Simulates what `finishBootstrap` does on the Task's success path.
        provider.clearRootUnavailableOnSuccessfulResolve()
        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .browsable,
                       "a successful resolve must clear a stale .rootUnavailable override, not gate forever")
    }

    /// Finding 1 (second half): the same success path must NEVER clear a
    /// `.switchingRoot` override — only `endRootSwitch()` may do that, or a
    /// `rebootstrap()` racing mid-switch would prematurely un-gate a switch
    /// that hasn't finished.
    func testSuccessfulResolveNeverClearsASwitchingRootOverride() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        provider.beginRootSwitch()
        XCTAssertEqual(provider.libraryGate, .switchingRoot)

        provider.clearRootUnavailableOnSuccessfulResolve()
        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .switchingRoot,
                       "a successful resolve must not stomp an in-progress .switchingRoot override")
    }

    /// Finding 2: `endRootSwitch()` must not silently discard a
    /// `.rootUnavailable` discovered mid-switch (e.g. a `rebootstrap()` that
    /// hit `LibraryRootError.unavailable` while a switch was running) — doing
    /// so would wipe the only explanation for what went wrong and recompute
    /// back to a bare, unexplained `.loading`.
    func testEndRootSwitchPreservesRootUnavailableDiscoveredMidSwitch() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        provider.beginRootSwitch()
        XCTAssertEqual(provider.libraryGate, .switchingRoot)

        let goneURL = URL(fileURLWithPath: "/Volumes/Gone/Library")
        provider.reportRootUnavailable(goneURL)   // simulates a mid-switch rebootstrap() failure
        XCTAssertEqual(provider.libraryGate, .rootUnavailable(goneURL))

        await provider.endRootSwitch()
        XCTAssertEqual(provider.libraryGate, .rootUnavailable(goneURL),
                       "endRootSwitch must preserve a .rootUnavailable discovered mid-switch")
    }

    /// `endRootSwitch()`'s normal case: a switch that finished cleanly clears
    /// `.switchingRoot` and lets the gate recompute to the real state.
    func testEndRootSwitchClearsASwitchingRootOverrideOnCleanFinish() async throws {
        let dir = try makeDir()
        let vault = makeVault(dir)
        _ = try await vault.configure(password: "pw")
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)

        provider.beginRootSwitch()
        XCTAssertEqual(provider.libraryGate, .switchingRoot)

        await provider.endRootSwitch()
        XCTAssertEqual(provider.libraryGate, .browsable)
    }
}
