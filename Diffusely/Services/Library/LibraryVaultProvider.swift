import Foundation
import Combine

/// Thrown by the enable/disable entry points when there is no vault to act on
/// — a `.custom` root is plaintext by construction, so `encryptionCoordinator()`
/// returns `nil` there. Settings hides the affordances that reach these calls
/// once a root switcher exists to offer a custom root (Task 8), so this is a
/// defensive rather than a routinely-user-facing error; the generic
/// catch-all in `LibraryEncryptionSettingsView.legibleMessage(for:action:)`
/// gives it a serviceable fallback message rather than crashing.
enum LibraryVaultProviderError: Error {
    case noVault
}

/// App-facing coordinator: owns the `LibraryVault`, publishes its state for UI
/// gating, and vends a `LibraryFileStore` bound to the current unlock state.
///
/// Lifecycle: the injectable initializer (used by tests and previews) sets
/// `vault` immediately, so it is never `nil` on that path. The production
/// `shared` singleton starts with `vault == nil` because resolving the
/// iCloud-backed items directory is blocking, actor-isolated I/O that must
/// never run synchronously on the main thread (this codebase has hit the
/// grey-spinner/cooperative-pool-starvation class of bugs from exactly that
/// pattern before). Call `bootstrap()` once, early — the app-entry wiring for
/// that is a later task — but `fileStore()` and `refreshState()` also call it
/// so out-of-order use degrades safely (pre-bootstrap: `state` reads
/// `.notConfigured`, `fileStore()` vends a passthrough store) instead of
/// crashing. `bootstrap()` is idempotent: the first call does the resolution
/// work, every later call awaits that same result.
@MainActor
final class LibraryVaultProvider: ObservableObject {
    @Published private(set) var state: LibraryVault.State = .notConfigured

    /// Coarse, single-source-of-truth gate the Library tab (Task 17) switches
    /// on. Deliberately carries NO associated `Phase`: Task 17 keys
    /// `.task(id: libraryGate)` on it, so it must NOT churn on every migration
    /// progress tick (the fine done/total lives in `migrationPhase`). Starts
    /// `.loading` and is flipped to the real gate by the first `bootstrap()`.
    enum LibraryGate: Equatable {
        /// Provider hasn't resolved the real vault state yet (pre-bootstrap).
        case loading
        /// Vault configured but locked — the Library needs an unlock first.
        case locked
        /// A forward/reverse migration is actively running.
        case migrating
        /// Vault configured + unlocked, but plaintext files still await
        /// encryption (a partial/failed enable) — browsing would let reconcile
        /// prune the index against the half-encrypted store.
        case setupIncomplete
        /// Safe to browse: encryption off, or fully-migrated + unlocked.
        case browsable
        /// A root switch is running: the old root is quiesced and the new one
        /// isn't indexed yet, so nothing may read or reconcile.
        case switchingRoot
        /// The saved custom root isn't there (unplugged volume, renamed folder),
        /// or a switch failed partway. Carries the path so the UI can name it —
        /// or `nil` when the failure has no folder of its own to name (a failed
        /// switch back to iCloud). `nil` is NOT a stand-in for an unknown path:
        /// it is the honest statement that no user-chosen folder is implicated,
        /// and the UI words itself accordingly rather than naming "/".
        /// Deliberately blocks rather than falling back to iCloud: a reconcile
        /// against a missing root would prune the index to nothing.
        case rootUnavailable(URL?)
    }

    @Published private(set) var libraryGate: LibraryGate = .loading

    /// Live done/total for the progress UI, mirrored from the coordinator's
    /// `phase` via `onPhaseChange`. Both the Settings inline progress and the
    /// Library tab's block view read this; `libraryGate` stays coarse.
    @Published private(set) var migrationPhase: LibraryEncryptionCoordinator.Phase = .idle

    /// `nil` only before the production singleton's `bootstrap()` completes;
    /// the injectable initializer (tests/previews) sets it immediately.
    private(set) var vault: LibraryVault?
    private var itemsDirectory: URL?
    private var bootstrapTask: Task<Void, Never>?

    /// Set by `LibraryRootCoordinator` while a switch runs, or when a root is
    /// found missing. Outranks every vault consideration.
    private var rootOverride: LibraryGate?

    /// True when the active root is `.custom` — unconditionally plaintext, so
    /// there is no vault to resolve and no reason to fail closed on a nil one.
    private var isPlaintextRoot = false

    /// Lazily built + cached by `encryptionCoordinator()`.
    private var encryptionCoordinatorInstance: LibraryEncryptionCoordinator?

    /// Dedicated queue for the `.unlocked`-branch pending-plaintext directory
    /// listing in `recomputeGate()`, so that (cheap but still blocking) scan
    /// never runs on the main actor — same cooperative-pool discipline the
    /// vault KDF and migration queues follow.
    private static let gateScanQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.vaultprovider.gatescan",
        qos: .userInitiated
    )

    /// Injectable initializer for tests/previews: `vault` is set immediately.
    init(vault: LibraryVault, itemsDirectory: URL) {
        self.vault = vault
        self.itemsDirectory = itemsDirectory
    }

    private init() {}

    /// Production singleton wired to the real container + biometric key
    /// store. Not usable until `bootstrap()` completes.
    static let shared = LibraryVaultProvider()

    /// Resolves the real `LibraryVault` + items directory off the app's
    /// iCloud container, then (once) flips `libraryGate` off `.loading` to the
    /// real gate. Safe to call from anywhere, any number of times — only the
    /// first call does the (async, actor-isolated) resolution work; later calls
    /// just await that result. No-op resolution on the injectable init path
    /// (`vault` is already set).
    func bootstrap() async {
        await resolveIfNeeded()
        // Flip the coarse gate off its initial `.loading` exactly once, right
        // after the first resolution (from whichever entry point resolved the
        // vault first). Guarding on `.loading` keeps later idempotent
        // bootstrap() calls from the hot paths (`fileStore`/`reconcileContext`)
        // from re-scanning; `refreshState()` and phase changes recompute
        // thereafter.
        if libraryGate == .loading {
            await recomputeGate()
        }
    }

    /// True when this process is hosting a test bundle. Checked three ways
    /// because the environment variables are set by the XCTest harness while the
    /// class lookup catches any path that loads XCTest without them.
    nonisolated static let isRunningInTestHost: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Resolves the real `LibraryVault` + items directory (the async,
    /// actor-isolated work). Idempotent: only the first call does the
    /// resolution, later calls await that same result; a no-op on the
    /// injectable init path (`vault` already set).
    ///
    /// Deliberately resolves NOTHING in a test host, leaving `vault == nil` so
    /// `state` reads `.notConfigured` and `reconcileContext()` returns
    /// `(.notConfigured, crypto: nil)`. Every service that defaults its
    /// vault-context seam to this singleton — `LibraryIndexService.reconcile`,
    /// `LibraryAlbumService`, `FileLibraryBackfillSidecarStore`,
    /// `SortAssistantScanner`/`Service`, `LibrarySaveService` — documents that
    /// default as safe because "the test process never configures the shared
    /// vault". That assumption silently became FALSE once encryption was enabled
    /// on the real Library: the unit test host is the app, so this resolved the
    /// real iCloud container, found its `vault.json`, and reported `.locked`.
    /// Every reconcile in the suite then no-opped through its locked guard and
    /// ingested nothing, failing ~99 tests (one of which trapped on an empty
    /// array and crashed the whole test worker, reporting unrelated suites as
    /// failures too). Making the assumption true by construction fixes the whole
    /// family at once and can't be forgotten by a future test — and it stops the
    /// suite reading the real Library container at all. Tests that need a real
    /// vault use the injectable initializer, which never reaches this method.
    private func resolveIfNeeded() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard vault == nil else { return }
        guard !Self.isRunningInTestHost else { return }

        let task = Task {
            do {
                let container = LibraryContainer.shared
                let root = await container.root
                let dir = try await container.itemsDirectory()

                if root.isCustom {
                    // Custom roots are unconditionally plaintext. Build no vault
                    // at all: `vaultURLs()` throws there by design, and a nil
                    // vault already yields a passthrough file store.
                    self.finishBootstrap(vault: nil, itemsDirectory: dir, isPlaintextRoot: true)
                    return
                }

                let urls = try await container.vaultURLs()
                let vault = LibraryVault(vaultURL: urls.vault, backupURL: urls.backup,
                                          keyStore: KeychainKeyStore(), rounds: 600_000)
                self.finishBootstrap(vault: vault, itemsDirectory: dir, isPlaintextRoot: false)
            } catch let error as LibraryRootError {
                // A missing custom root is a real, reportable state — not a
                // transient hiccup to retry silently.
                if case .unavailable(let url) = error {
                    self.rootOverride = .rootUnavailable(url)
                    self.libraryGate = .rootUnavailable(url)
                }
                self.bootstrapTask = nil
            } catch {
                // Directory resolution failed (e.g. disk full). Leave `vault`
                // nil so state stays `.notConfigured`/passthrough, and clear
                // `bootstrapTask` so a later call retries instead of being
                // stuck awaiting this failed attempt forever.
                self.bootstrapTask = nil
            }
        }
        bootstrapTask = task
        await task.value
    }

    private func finishBootstrap(vault: LibraryVault?, itemsDirectory: URL, isPlaintextRoot: Bool) {
        self.vault = vault
        self.itemsDirectory = itemsDirectory
        self.isPlaintextRoot = isPlaintextRoot
        // A real resolve just succeeded: a stale `.rootUnavailable` from an
        // earlier failed resolve (or a `rebootstrap()` mid-switch) no longer
        // describes reality, and nothing else ever clears it — `bootstrap()`'s
        // `.loading` latch won't fire again once the gate has already moved
        // off `.loading`, so without this a root plugged back in would leave
        // the Library gated for the rest of the process's life. Deliberately
        // narrow: never clears `.switchingRoot` here — only `endRootSwitch()`
        // may do that, so a `rebootstrap()` that runs mid-switch can't
        // prematurely un-gate a switch that hasn't finished yet.
        clearRootUnavailableOnSuccessfulResolve()
    }

    /// Clears a `.rootUnavailable` override on a successful resolve; a no-op
    /// for any other override (in particular `.switchingRoot`, which only
    /// `endRootSwitch()` may clear). Factored out of `finishBootstrap` and
    /// left internal (not `private`) so it's directly unit-testable: the real
    /// resolve Task in `resolveIfNeeded()` never runs in the test host (see
    /// `isRunningInTestHost`), so this is the only way to exercise "a
    /// successful resolve clears the stale override" without a real container.
    func clearRootUnavailableOnSuccessfulResolve() {
        if case .rootUnavailable = rootOverride { rootOverride = nil }
    }

    /// Tears down the resolved vault and resolves again against whatever root
    /// `LibraryContainer` now holds. Used by `LibraryRootCoordinator` mid-switch.
    func rebootstrap() async {
        bootstrapTask = nil
        vault = nil
        itemsDirectory = nil
        isPlaintextRoot = false
        await resolveIfNeeded()
        await recomputeGate()
    }

    func beginRootSwitch() {
        rootOverride = .switchingRoot
        libraryGate = .switchingRoot
    }

    /// `url` is the folder that is missing, or `nil` when the failure names no
    /// folder of the user's (a failed switch back to iCloud). See
    /// `LibraryGate.rootUnavailable`.
    func reportRootUnavailable(_ url: URL?) {
        rootOverride = .rootUnavailable(url)
        libraryGate = .rootUnavailable(url)
    }

    /// True when a vault is configured and locked RIGHT NOW.
    ///
    /// `LibraryRootCoordinator` asks this straight after `rebootstrap()`.
    /// Switching back to an encrypted iCloud root builds a FRESH `LibraryVault`
    /// with no cached DEK, so it reports `.locked` the moment `vault.json`
    /// exists — nothing auto-unlocks, since only the unlock UI calls
    /// `unlockWithBiometrics()`. The index rebuild therefore correctly declines
    /// to scan, and without this question the coordinator would read that
    /// correct outcome as a failed switch and strand the user behind a blocking
    /// gate that the unlock UI can't be reached from.
    func isVaultLocked() async -> Bool {
        await vault?.state() == .locked
    }

    /// Ends a root switch, clearing only the `.switchingRoot` override that
    /// `beginRootSwitch()` set. If a `rebootstrap()` run during the switch hit
    /// `LibraryRootError.unavailable` and reported `.rootUnavailable` instead,
    /// that discovery must survive this call — blanket-clearing it here would
    /// wipe the one signal that state exists and let the gate recompute back
    /// to a bare `.loading` with no explanation of what went wrong.
    func endRootSwitch() async {
        if case .switchingRoot = rootOverride { rootOverride = nil }
        await recomputeGate()
    }

    /// Builds a `LibraryFileStore` over the resolved items directory using
    /// the current unlock state's crypto (encrypted when unlocked,
    /// passthrough otherwise).
    func fileStore() async -> LibraryFileStore {
        await bootstrap()
        // Read the directory AND the root's plaintext-ness BEFORE the await
        // below, so the pair describes one root. A `rebootstrap()` landing on
        // this actor at that suspension point would otherwise pair one root's
        // directory with the other's `createsContainerDirectory` — which, at a
        // custom root, means recreating a folder tree at a path that is
        // deliberately never created.
        let directory = resolvedDirectory()
        let createsContainerDirectory = !isPlaintextRoot
        let crypto = await vault?.crypto()
        return LibraryFileStore(itemsDirectory: directory, crypto: crypto,
                                 createsContainerDirectory: createsContainerDirectory)
    }

    /// Atomic `(state, store)` pair for reconcile/rebuild: both derived from
    /// one `LibraryVault.snapshot()` call, so the locked-or-not decision and
    /// the crypto the returned store scans with can never disagree. Reading
    /// `state` and `fileStore()` separately (as reconcile originally did) is
    /// a TOCTOU race — the vault can lock() on its actor between those two
    /// independent awaits, so a caller could see `.unlocked` from the first
    /// read but get a passthrough (`crypto == nil`) store from the second,
    /// over a container that is actually encrypted. That combination let a
    /// scan find zero sidecars and prune every index row. `snapshot()` reads
    /// both fields in a single actor-isolated call with no suspension point
    /// between them, closing the gap.
    func reconcileContext() async -> (state: LibraryVault.State, store: LibraryFileStore) {
        await bootstrap()
        // Same discipline as `fileStore()`: directory + plaintext-ness captured
        // together, before the vault await, so they can't describe two roots.
        let directory = resolvedDirectory()
        let createsContainerDirectory = !isPlaintextRoot
        let snap = await vault?.snapshot() ?? (state: .notConfigured, crypto: nil)
        return (snap.state, LibraryFileStore(itemsDirectory: directory, crypto: snap.crypto,
                                              createsContainerDirectory: createsContainerDirectory))
    }

    /// The directory a vended `LibraryFileStore` should use — the real
    /// resolved items directory once `bootstrap()` has completed, or a
    /// dedicated scratch fallback while unresolved/failed. See `fileStore()`'s
    /// original doc comment for why the fallback is a namespaced subdirectory
    /// rather than the bare system temp root. Callers must `await bootstrap()`
    /// first.
    private func resolvedDirectory() -> URL {
        if let itemsDirectory {
            return itemsDirectory
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryVaultProvider-unresolved", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func refreshState() async {
        await resolveIfNeeded()
        state = await vault?.state() ?? .notConfigured
        await recomputeGate()
    }

    // MARK: - Library gate

    /// Lazily builds (once) + caches the app's `LibraryEncryptionCoordinator`,
    /// wired so its progress mirrors into this provider: every `phase` change
    /// updates `migrationPhase` and recomputes `libraryGate` (so `.migrating`
    /// engages the instant a migration starts and clears the instant it ends).
    ///
    /// Uses the coordinator's own `defaultRebuildIndex` — the production
    /// index-rebuild the app already runs after a migration (resolve the
    /// container dir + rebuild through `LibrarySaveService.shared.indexService`)
    /// — by not passing a `rebuildIndex` argument, so enabling/disabling here
    /// rebuilds the index exactly as a standalone coordinator would.
    ///
    /// Returns `nil` when there is no vault to coordinate. That is now a
    /// NORMAL outcome, not an exceptional one: a `.custom` root is plaintext
    /// by construction (Step 5), so `vault` stays `nil` for the life of the
    /// process and there is nothing for a coordinator to enable/disable/
    /// migrate. Awaits `bootstrap()` first, so the `nil` this returns always
    /// reflects the resolved root, not an unresolved one.
    func encryptionCoordinator() async -> LibraryEncryptionCoordinator? {
        await bootstrap()
        guard let vault else { return nil }
        if let encryptionCoordinatorInstance {
            return encryptionCoordinatorInstance
        }
        let coordinator = LibraryEncryptionCoordinator(
            itemsDirectory: resolvedDirectory(),
            vault: vault
        )
        coordinator.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.migrationPhase = phase
            Task { await self.recomputeGate() }
        }
        encryptionCoordinatorInstance = coordinator
        return coordinator
    }

    // MARK: - Enable / disable (provider-owned, gate-aware)
    //
    // These are the intended entry points for the Task 16b Settings UI. They
    // live on the provider — not just on the coordinator — so the gate is
    // recomputed at every transition the UI can't be trusted to remember. In
    // particular `enableConfigure` recomputes AFTER `configureVault`: that call
    // never assigns `phase`, so `onPhaseChange` never fires, and the window
    // between it returning (vault unlocked over ALL-plaintext files) and
    // `runEnableMigration`'s first `.encrypting` tick is user-paced — without
    // this recompute the gate would sit at a stale `.browsable` while the store
    // is fully plaintext-under-an-encrypted-vault, exactly the half-migrated
    // exposure the gate exists to prevent.

    /// Configure the vault (writes `vault.json`, caches the DEK, returns the
    /// one-time recovery key) WITHOUT migrating, then recompute the gate — which
    /// lands `.setupIncomplete` because every file is still plaintext (pending
    /// > 0). The 16b UI shows/acknowledges the recovery key, then calls
    /// `runEnableMigration()`.
    func enableConfigure(password: String) async throws -> String {
        guard let coordinator = await encryptionCoordinator() else {
            throw LibraryVaultProviderError.noVault
        }
        let key = try await coordinator.configureVault(password: password)
        await recomputeGate()
        return key
    }

    /// Run (or resume) the forward migration. `onPhaseChange` drives the gate to
    /// `.migrating` while it runs; the explicit recompute settles it
    /// deterministically on return (`.browsable` on full success,
    /// `.setupIncomplete` if it threw partway) before the caller continues.
    func runEnableMigration() async throws {
        guard let coordinator = await encryptionCoordinator() else {
            throw LibraryVaultProviderError.noVault
        }
        do {
            try await coordinator.runEnableMigration()
        } catch {
            await recomputeGate()
            throw error
        }
        await recomputeGate()
    }

    /// True iff the vault is configured but plaintext still awaits encryption
    /// (a partial/failed enable). Retained for callers that only need the
    /// forward-pending signal; the resume UI uses `incompleteMigrationDirection`
    /// instead so it can also recognize an interrupted DISABLE.
    func isEnableIncomplete() async -> Bool {
        guard let coordinator = await encryptionCoordinator() else { return false }
        return await coordinator.isEnableIncomplete()
    }

    /// The direction an interrupted migration should resume in (or `nil` when
    /// complete) — see `LibraryEncryptionCoordinator.incompleteMigrationDirection`.
    /// Drives the direction-aware Settings "Resume" affordance and the Library
    /// tab's setup-incomplete block copy, so an interrupted disable resumes by
    /// decrypting rather than being misread as an interrupted enable.
    func incompleteMigrationDirection() async -> LibraryMigrationDirection? {
        guard let coordinator = await encryptionCoordinator() else { return nil }
        return await coordinator.incompleteMigrationDirection()
    }

    /// Turn encryption off: reverse-migrate to plaintext + tear down the vault,
    /// then recompute the gate (which lands `.browsable`, encryption now off).
    func disableEncryption() async throws {
        guard let coordinator = await encryptionCoordinator() else {
            throw LibraryVaultProviderError.noVault
        }
        do {
            try await coordinator.disable()
        } catch {
            await recomputeGate()
            throw error
        }
        await recomputeGate()
    }

    /// Recomputes the coarse `libraryGate` from the live vault state + any
    /// active migration, assigning only on a real change so the gate doesn't
    /// re-emit on every migration progress tick. Cheap in every case except
    /// `.unlocked`, where it offloads a single pending-plaintext directory
    /// listing to `gateScanQueue` (never the main actor). Called after the
    /// initial bootstrap resolution, from `refreshState()`, and on every
    /// coordinator phase change.
    private func recomputeGate() async {
        let target = await computedGate()
        if libraryGate != target { libraryGate = target }
    }

    /// Pure gate decision, extracted so precedence is unit-testable without the
    /// singleton. `vaultState == nil` means the vault hasn't resolved.
    nonisolated static func computedGate(
        rootOverride: LibraryGate?,
        migrationPhase: LibraryEncryptionCoordinator.Phase,
        isPlaintextRoot: Bool,
        vaultState: LibraryVault.State?,
        pendingPlaintextCount: Int
    ) -> LibraryGate {
        // A root switch, or a root that isn't there, blocks ahead of everything:
        // the vault below describes a root we may no longer be pointed at.
        if let rootOverride { return rootOverride }

        switch migrationPhase {
        case .encrypting, .decrypting:
            return .migrating
        case .idle, .failed:
            break
        }

        // A custom root is plaintext by construction — no vault, nothing to
        // fail closed about.
        if isPlaintextRoot { return .browsable }

        // Fail CLOSED, never open, when an iCloud vault hasn't resolved: a nil
        // vault must not be conflated with the real `.notConfigured` state, or a
        // reconcile could prune against the empty fallback scratch directory.
        guard let vaultState else { return .loading }

        switch vaultState {
        case .locked:
            return .locked
        case .notConfigured:
            return .browsable
        case .unlocked:
            return pendingPlaintextCount > 0 ? .setupIncomplete : .browsable
        }
    }

    private func computedGate() async -> LibraryGate {
        let snapshot = await vault?.snapshot()

        // The static below is the ONLY place the gate is decided. The guard
        // here decides something narrower: whether the expensive part — a
        // blocking directory listing on `gateScanQueue` — is worth doing at
        // all. It is only ever consulted for an unlocked, configured vault
        // that nothing else is already blocking.
        let migrationBlocks: Bool
        switch migrationPhase {
        case .encrypting, .decrypting: migrationBlocks = true
        case .idle, .failed: migrationBlocks = false
        }

        var pending = 0
        if rootOverride == nil, !isPlaintextRoot, !migrationBlocks,
           snapshot?.state == .unlocked, let crypto = snapshot?.crypto {
            pending = await Self.scanPendingPlaintextCount(
                directory: resolvedDirectory(), crypto: crypto)
        }

        return Self.computedGate(
            rootOverride: rootOverride,
            migrationPhase: migrationPhase,
            isPlaintextRoot: isPlaintextRoot,
            vaultState: snapshot?.state,
            pendingPlaintextCount: pending
        )
    }

    /// Off-main directory listing of pending plaintext items + aux files (no
    /// file reads, no crypto — see `LibraryEncryptionMigrator
    /// .pendingItemsAndAuxCount`). Runs on `gateScanQueue`.
    private static func scanPendingPlaintextCount(directory: URL, crypto: LibraryFileCrypto) async -> Int {
        await withCheckedContinuation { continuation in
            gateScanQueue.async {
                let migrator = LibraryEncryptionMigrator(itemsDirectory: directory, crypto: crypto)
                continuation.resume(returning: migrator.pendingItemsAndAuxCount())
            }
        }
    }
}
