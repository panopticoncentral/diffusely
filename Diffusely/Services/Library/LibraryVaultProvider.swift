import Foundation
import Combine

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

    /// Resolves the real `LibraryVault` + items directory (the async,
    /// actor-isolated work). Idempotent: only the first call does the
    /// resolution, later calls await that same result; a no-op on the
    /// injectable init path (`vault` already set).
    private func resolveIfNeeded() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard vault == nil else { return }

        let task = Task {
            do {
                let container = LibraryContainer.shared
                let dir = try await container.itemsDirectory()
                let urls = try await container.vaultURLs()
                let vault = LibraryVault(vaultURL: urls.vault, backupURL: urls.backup,
                                          keyStore: KeychainKeyStore(), rounds: 600_000)
                self.finishBootstrap(vault: vault, itemsDirectory: dir)
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

    private func finishBootstrap(vault: LibraryVault, itemsDirectory: URL) {
        self.vault = vault
        self.itemsDirectory = itemsDirectory
    }

    /// Builds a `LibraryFileStore` over the resolved items directory using
    /// the current unlock state's crypto (encrypted when unlocked,
    /// passthrough otherwise).
    func fileStore() async -> LibraryFileStore {
        await bootstrap()
        return LibraryFileStore(itemsDirectory: resolvedDirectory(), crypto: await vault?.crypto())
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
        let snap = await vault?.snapshot() ?? (state: .notConfigured, crypto: nil)
        return (snap.state, LibraryFileStore(itemsDirectory: resolvedDirectory(), crypto: snap.crypto))
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
    /// Precondition: `bootstrap()` has resolved a real vault (it awaits it
    /// first). The production `.shared` provider always resolves against the
    /// real container before this is reachable from Settings; the force-unwrap
    /// matches the coordinator's non-optional `vault` requirement.
    func encryptionCoordinator() async -> LibraryEncryptionCoordinator {
        await bootstrap()
        if let encryptionCoordinatorInstance {
            return encryptionCoordinatorInstance
        }
        let coordinator = LibraryEncryptionCoordinator(
            itemsDirectory: resolvedDirectory(),
            vault: vault!
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
        let key = try await encryptionCoordinator().configureVault(password: password)
        await recomputeGate()
        return key
    }

    /// Run (or resume) the forward migration. `onPhaseChange` drives the gate to
    /// `.migrating` while it runs; the explicit recompute settles it
    /// deterministically on return (`.browsable` on full success,
    /// `.setupIncomplete` if it threw partway) before the caller continues.
    func runEnableMigration() async throws {
        do {
            try await encryptionCoordinator().runEnableMigration()
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
        await encryptionCoordinator().isEnableIncomplete()
    }

    /// The direction an interrupted migration should resume in (or `nil` when
    /// complete) — see `LibraryEncryptionCoordinator.incompleteMigrationDirection`.
    /// Drives the direction-aware Settings "Resume" affordance and the Library
    /// tab's setup-incomplete block copy, so an interrupted disable resumes by
    /// decrypting rather than being misread as an interrupted enable.
    func incompleteMigrationDirection() async -> LibraryMigrationDirection? {
        await encryptionCoordinator().incompleteMigrationDirection()
    }

    /// Turn encryption off: reverse-migrate to plaintext + tear down the vault,
    /// then recompute the gate (which lands `.browsable`, encryption now off).
    func disableEncryption() async throws {
        do {
            try await encryptionCoordinator().disable()
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

    private func computedGate() async -> LibraryGate {
        // An actively running migration blocks the Library outright, ahead of
        // any vault-state consideration.
        switch migrationPhase {
        case .encrypting, .decrypting:
            return .migrating
        case .idle, .failed:
            break
        }

        // Fail CLOSED, never open, when the vault hasn't resolved. A `nil`
        // vault (bootstrap not run yet, or resolution failed on a transient
        // iCloud/disk hiccup) must NOT be conflated with the real
        // `.notConfigured` shipping state: falling through to `.browsable`
        // there would let Task 17 permit a reconcile/prune against the empty
        // fallback scratch directory. Stay `.loading` (blocked) instead — and
        // since `bootstrap()` only recomputes while `.loading`, this keeps the
        // gate retrying until the vault genuinely resolves.
        guard let vault else { return .loading }
        let snapshot = await vault.snapshot()
        switch snapshot.state {
        case .locked:
            return .locked
        case .notConfigured:
            // Shipping path: encryption off. Do NOT scan the directory.
            return .browsable
        case .unlocked:
            // Configured + unlocked: browsable only if fully migrated. A
            // leftover plaintext count (partial/failed enable) means the store
            // is half-encrypted — gate as `.setupIncomplete` so the Library
            // tab blocks reconcile from pruning the index against it.
            guard let crypto = snapshot.crypto else { return .browsable }
            let pending = await Self.scanPendingPlaintextCount(
                directory: resolvedDirectory(), crypto: crypto)
            return pending > 0 ? .setupIncomplete : .browsable
        }
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
