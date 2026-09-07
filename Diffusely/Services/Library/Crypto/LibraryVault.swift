import Foundation
import CryptoKit

/// Session-scoped source of truth for Library encryption. Owns the vault file
/// on disk and the in-memory DEK. File I/O here is fast enough for the actor,
/// but the PBKDF2-backed crypto calls (`configure`/`unlock`/`changePassword`)
/// are bridged to a dedicated queue — see `kdfQueue` below — so callers can
/// invoke them from anywhere without risking cooperative-pool starvation.
actor LibraryVault {
    enum State: Equatable { case notConfigured, locked, unlocked }

    private let vaultURL: URL
    private let backupURL: URL
    private let keyStore: LibraryKeyStore
    private let rounds: UInt32

    private var dek: SymmetricKey?

    /// Dedicated serial queue for the blocking PBKDF2 work inside
    /// `LibraryVaultCrypto.create`/`.unlock`/`.rewrapPassword`. At the
    /// production round count (600_000) that derivation takes ~0.3-0.5s;
    /// running it directly on the actor's executor would occupy a Swift
    /// concurrency cooperative-pool thread for that long and risks
    /// reproducing this app's documented grey-spinner cooperative-pool
    /// starvation regression. Mirrors
    /// `LibraryEncryptionCoordinator.ioQueue`/`.runOnIOQueue(_:)`.
    private static let kdfQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.vault.kdf",
        qos: .userInitiated
    )

    /// Runs a blocking `LibraryVaultCrypto` call on `kdfQueue` and suspends
    /// the caller until it finishes, without occupying a cooperative thread.
    /// `work` must not touch actor state (`self`) — it runs off the actor;
    /// callers resume on the actor after the `await` to mutate `dek`, persist
    /// the vault file, and update the key store.
    private static func runOnKDFQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            kdfQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Whether a vault file's *contents* are actually on local disk.
    /// `notDownloaded` is deliberately distinct from `absent`: an evicted
    /// iCloud placeholder still means the vault is configured.
    enum Materialization: Equatable, Sendable { case absent, notDownloaded, materialized }

    /// Seam for the materialization probe. Production uses the iCloud
    /// downloading-status check; tests inject a stub, because a genuinely
    /// dataless file can't be created locally.
    typealias MaterializationProbe = @Sendable (URL) -> Materialization

    private let materialization: MaterializationProbe

    /// Dedicated serial queue for vault-file reads. `Data(contentsOf:)` over
    /// the iCloud container is blocking I/O, and must not occupy a Swift
    /// concurrency cooperative thread — same discipline as `kdfQueue` and
    /// `LibraryEncryptionCoordinator.ioQueue`.
    private static let ioQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.vault.io",
        qos: .userInitiated
    )

    private static func runOnIOQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    init(vaultURL: URL, backupURL: URL, keyStore: LibraryKeyStore, rounds: UInt32,
         materialization: @escaping MaterializationProbe = LibraryVault.probeMaterialization) {
        self.vaultURL = vaultURL
        self.backupURL = backupURL
        self.keyStore = keyStore
        self.rounds = rounds
        self.materialization = materialization
    }

    func state() -> State {
        if dek != nil { return .unlocked }
        return vaultFileExists() ? .locked : .notConfigured
    }

    func crypto() -> LibraryFileCrypto? {
        dek.map { LibraryFileCrypto(dek: $0) }
    }

    /// URL of a small coordinator-owned marker file living in the SAME durable
    /// directory as the vault file itself (a sibling of `vault.json`, not inside
    /// the items directory), used to record that a reverse (disable) migration
    /// is in progress. Persisting it right next to the vault means an
    /// interrupted disable stays recognizable AS a disable — rather than being
    /// misread as an interrupted enable from the forward-pending plaintext count
    /// — across a crash/relaunch. `nonisolated`: derived purely from the
    /// immutable `let vaultURL`, so it needs no actor hop and can be read
    /// synchronously by the (main-actor) coordinator.
    nonisolated var disableInProgressMarkerURL: URL {
        vaultURL.deletingLastPathComponent().appendingPathComponent("vault.disabling")
    }

    /// Atomic `(state, crypto)` pair — both derived from the same
    /// actor-isolated call, with no suspension point between them. A caller
    /// that instead reads `state()` and `crypto()` separately (two distinct
    /// awaits) can observe them disagree if `lock()`/`unlock` runs on this
    /// actor in between — e.g. seeing `.unlocked` from the first call but
    /// `nil` crypto from the second, because the vault locked in the gap.
    /// `LibraryVaultProvider.reconcileContext()` depends on this atomicity so
    /// reconcile's locked-guard and the store it scans with can never
    /// disagree about whether the vault was locked.
    func snapshot() -> (state: State, crypto: LibraryFileCrypto?) {
        (state(), crypto())
    }

    func configure(password: String) async throws -> String {
        guard !vaultFileExists() else { throw LibraryVaultError.malformed }
        let rounds = self.rounds
        let (file, dek, recovery) = try await Self.runOnKDFQueue {
            try LibraryVaultCrypto.create(password: password, rounds: rounds)
        }
        try writeFile(file)
        self.dek = dek
        try? keyStore.store(dek: dek.withUnsafeBytes { Data($0) })
        return recovery
    }

    func unlock(password: String) async throws {
        let file = try await requireFile()
        let key = try await Self.runOnKDFQueue {
            try LibraryVaultCrypto.unlock(file, password: password)
        }
        self.dek = key
        try? keyStore.store(dek: key.withUnsafeBytes { Data($0) })
    }

    func unlock(recoveryKey: String) async throws {
        let file = try await requireFile()
        let key = try await Self.runOnKDFQueue {
            try LibraryVaultCrypto.unlock(file, recoveryKey: recoveryKey)
        }
        self.dek = key
        try? keyStore.store(dek: key.withUnsafeBytes { Data($0) })
    }

    func unlockWithBiometrics() async -> Bool {
        guard case .loaded = await loadFile() else { return false }
        guard let raw = try? await keyStore.loadWithBiometrics(reason: "Unlock your Library"), !raw.isEmpty else {
            return false
        }
        self.dek = SymmetricKey(data: raw)
        return true
    }

    func lock() { dek = nil }

    /// True when the vault file is present but its contents aren't downloaded
    /// from iCloud yet. `unlockWithBiometrics()` reports a plain `false` for
    /// every failure by design, so the unlock UI needs this to tell "the file
    /// isn't here yet" apart from "biometrics unavailable" — otherwise it has
    /// nothing to show the user but a disabled button.
    func isAwaitingDownload() async -> Bool {
        if case .notDownloaded = await loadFile() { return true }
        return false
    }


    func changePassword(old: String, new: String) async throws {
        let file = try await requireFile()
        let rewrapped = try await Self.runOnKDFQueue {
            let key = try LibraryVaultCrypto.unlock(file, password: old)
            return try LibraryVaultCrypto.rewrapPassword(file, dek: key, newPassword: new)
        }
        try writeFile(rewrapped)
    }

    func teardown() {
        dek = nil
        try? keyStore.clear()
        try? FileManager.default.removeItem(at: vaultURL)
        try? FileManager.default.removeItem(at: backupURL)
    }

    // MARK: - Persistence (primary + backup)

    /// Existence, not decodability — used by `state()`/`configure` so a present-but-corrupt
    /// vault file is never mistaken for "never configured" (which would let `configure` mint a
    /// fresh DEK and silently orphan whatever was encrypted under the old one).
    private func vaultFileExists() -> Bool {
        FileManager.default.fileExists(atPath: vaultURL.path) || FileManager.default.fileExists(atPath: backupURL.path)
    }

    /// Outcome of a vault-file load. `notDownloaded` must never collapse into
    /// `unavailable`: an evicted placeholder still means the vault exists.
    private enum Load { case loaded(LibraryVaultFile), notDownloaded, unavailable }

    private func requireFile() async throws -> LibraryVaultFile {
        switch await loadFile() {
        case .loaded(let file): return file
        case .notDownloaded: throw LibraryVaultError.notDownloaded
        case .unavailable: throw LibraryVaultError.malformed
        }
    }

    /// Reads the vault file, preferring the primary and falling back to the
    /// backup — but only ever reading a file whose contents are actually on
    /// local disk.
    ///
    /// Both files live in the app's iCloud ubiquity container, where macOS
    /// evicts contents under storage pressure ("dataless"), leaving the
    /// directory entry and its real size behind. `Data(contentsOf:)` on a
    /// dataless file blocks inside `read(2)` until the file provider
    /// materializes it — with no timeout and no catchable error — and when the
    /// provider is wedged it never returns at all. Doing that on the unlock
    /// path stranded the entire UI: `LibraryUnlockView` sets `busy = true`
    /// around this call, so a read that never returned left both "Unlock" and
    /// "Use Face ID" permanently disabled, with no way for the user to get out.
    ///
    /// So the materialization probe gates the read rather than the read
    /// discovering the problem the hard way: it answers in milliseconds even
    /// while the provider is wedged. A download is requested on the way past so
    /// a later retry can succeed. The read itself runs on `ioQueue`, never a
    /// cooperative thread.
    private func loadFile() async -> Load {
        let urls = [vaultURL, backupURL]
        let probe = materialization
        return await Self.runOnIOQueue {
            var sawPlaceholder = false
            for url in urls {
                switch probe(url) {
                case .absent:
                    continue
                case .notDownloaded:
                    // Present but evicted. Ask for it back; don't read it.
                    sawPlaceholder = true
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                case .materialized:
                    if let data = try? Data(contentsOf: url),
                       let file = try? JSONDecoder().decode(LibraryVaultFile.self, from: data) {
                        return .loaded(file)
                    }
                }
            }
            // A placeholder among the candidates outranks a missing/corrupt
            // sibling: the vault may well be intact, just not here yet.
            return sawPlaceholder ? .notDownloaded : .unavailable
        }
    }

    /// Production materialization probe. `fileExists` is true for a dataless
    /// placeholder, so existence alone says nothing about readability; the
    /// iCloud downloading status is what distinguishes them, and reading it is
    /// a fast metadata lookup that does not trigger a download or block.
    /// Anything that isn't a ubiquity item (the local fallback container,
    /// tests) is readable by definition.
    static let probeMaterialization: MaterializationProbe = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let values = try? url.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            values.isUbiquitousItem == true else { return .materialized }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded ? .notDownloaded : .materialized
    }

    private func writeFile(_ file: LibraryVaultFile) throws {
        let data = try JSONEncoder().encode(file)
        try data.write(to: vaultURL, options: .atomic)
        try data.write(to: backupURL, options: .atomic)
    }
}
