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

    init(vaultURL: URL, backupURL: URL, keyStore: LibraryKeyStore, rounds: UInt32) {
        self.vaultURL = vaultURL
        self.backupURL = backupURL
        self.keyStore = keyStore
        self.rounds = rounds
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
        guard let file = loadFile() else { throw LibraryVaultError.malformed }
        let key = try await Self.runOnKDFQueue {
            try LibraryVaultCrypto.unlock(file, password: password)
        }
        self.dek = key
        try? keyStore.store(dek: key.withUnsafeBytes { Data($0) })
    }

    func unlock(recoveryKey: String) async throws {
        guard let file = loadFile() else { throw LibraryVaultError.malformed }
        let key = try await Self.runOnKDFQueue {
            try LibraryVaultCrypto.unlock(file, recoveryKey: recoveryKey)
        }
        self.dek = key
        try? keyStore.store(dek: key.withUnsafeBytes { Data($0) })
    }

    func unlockWithBiometrics() async -> Bool {
        guard loadFile() != nil else { return false }
        guard let raw = try? await keyStore.loadWithBiometrics(reason: "Unlock your Library"), !raw.isEmpty else {
            return false
        }
        self.dek = SymmetricKey(data: raw)
        return true
    }

    func lock() { dek = nil }

    func changePassword(old: String, new: String) async throws {
        guard let file = loadFile() else { throw LibraryVaultError.malformed }
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

    private func loadFile() -> LibraryVaultFile? {
        for url in [vaultURL, backupURL] {
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(LibraryVaultFile.self, from: data) {
                return file
            }
        }
        return nil
    }

    private func writeFile(_ file: LibraryVaultFile) throws {
        let data = try JSONEncoder().encode(file)
        try data.write(to: vaultURL, options: .atomic)
        try data.write(to: backupURL, options: .atomic)
    }
}
