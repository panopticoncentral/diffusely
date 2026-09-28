import Foundation

/// The direction an interrupted Library migration should resume in. A
/// half-migrated container gates the Library non-`.browsable` either way, but
/// the RESUME action and its copy must run the correct way round: re-encrypting
/// a Library the user was decrypting (or vice versa) would be exactly wrong.
enum LibraryMigrationDirection: Equatable {
    /// A forward (enable) migration was interrupted — plaintext still awaits
    /// encryption. Resume by running the forward migration.
    case enable
    /// A reverse (disable) migration was interrupted — some items are back to
    /// plaintext but ciphertext remains and the vault is still configured.
    /// Resume by continuing to decrypt + tear the vault down.
    case disable
}

/// Orchestrates turning Library at-rest encryption ON and OFF: configuring
/// the vault, running the (potentially long) forward/reverse file migration,
/// and rebuilding the SwiftData index from the post-migration container —
/// publishing progress the eventual Settings/unlock UI (tasks 15-17) can
/// observe.
///
/// The whole migration loop runs on a dedicated background queue, never the
/// Swift concurrency cooperative pool: this repo has a documented recurring
/// bug class where blocking iCloud I/O on the cooperative pool starves ALL
/// async work app-wide onto permanent grey spinners (see
/// `LibraryFileMaterializer`, `LibraryImageRequest`, and
/// `LibraryIndexService`, each of which owns its own dedicated queue for
/// exactly this reason).
@MainActor
final class LibraryEncryptionCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case encrypting(done: Int, total: Int)
        case decrypting(done: Int, total: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }

    /// Optional hook fired on every `phase` change so an owner (the
    /// `LibraryVaultProvider`) can mirror progress into its own published
    /// `migrationPhase` and recompute the coarse Library gate. The `didSet` on
    /// `phase` above fires it for every assignment site — enable/migrate/
    /// disable/failed — including the `Task { @MainActor in self.phase = … }`
    /// progress ticks. `@MainActor` because both this coordinator and its only
    /// owner are main-actor isolated, so the call is a plain synchronous hop.
    /// Default `nil` keeps the coordinator's standalone behavior (and the
    /// existing coordinator tests) unchanged.
    var onPhaseChange: (@MainActor (Phase) -> Void)?

    private let itemsDirectory: URL
    private let vault: LibraryVault
    private let rebuildIndex: () async -> Void

    /// Dedicated serial queue for the migration loop's blocking file I/O
    /// (directory listings, per-item encrypt/decrypt, iCloud materialize
    /// waits) — mirrors `LibraryFileMaterializer.ioQueue` /
    /// `LibraryImageRequest.ioQueue` / `LibraryIndexService.scanQueue`.
    /// Serial, not concurrent: migration order matters both for the
    /// `(done, total)` progress sequence and for
    /// `LibraryEncryptionMigrator`'s documented crash-safety ordering (media
    /// before sidecar, items before aux) — two items must never migrate at
    /// the same time.
    private static let ioQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.migration",
        qos: .userInitiated
    )

    /// - Parameter rebuildIndex: Hook run after a successful enable/disable to
    ///   rebuild the SwiftData index from the (now migrated) container.
    ///   Defaults to `defaultRebuildIndex` (the real production wiring); tests
    ///   inject a no-op closure so `enable`/`disable` are unit-testable over a
    ///   temp directory without driving real SwiftData/iCloud.
    init(
        itemsDirectory: URL,
        vault: LibraryVault,
        rebuildIndex: @escaping () async -> Void = LibraryEncryptionCoordinator.defaultRebuildIndex
    ) {
        self.itemsDirectory = itemsDirectory
        self.vault = vault
        self.rebuildIndex = rebuildIndex
    }

    /// Real production `rebuildIndex` wiring: resolve the container directory
    /// via `LibraryContainer.shared` and rebuild through the shared
    /// `LibraryIndexService` that `LibrarySaveService.shared` holds a weak
    /// reference to (set by `LibraryStore.init`). Going through that weak
    /// reference — rather than requiring a direct `LibraryStore` dependency —
    /// keeps this coordinator decoupled from the `@MainActor LibraryStore`
    /// object graph; if the app hasn't wired a `LibraryStore` yet (or it's
    /// been torn down) this is a silent no-op, matching how
    /// `LibrarySaveService` itself already treats a nil `indexService`.
    ///
    /// A plain `static func` (referenced by name as the init's default
    /// argument) rather than an inline closure literal deliberately: an
    /// inline closure literal used as a default argument value in a
    /// `@MainActor` type's initializer triggers a compiler diagnostic quirk
    /// ("no 'async' operations occur within 'await' expression") that
    /// misreports the cross-actor hop into `LibraryContainer`'s own actor as
    /// dead code, even though the hop is real and required. Referencing a
    /// separately-declared static function sidesteps the quirk entirely.
    private static func defaultRebuildIndex() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        // No `await` needed for `LibrarySaveService.shared` itself: this
        // static function is a member of `LibraryEncryptionCoordinator`,
        // which is `@MainActor`, so it's already MainActor-isolated — the
        // same actor `LibrarySaveService` (also `@MainActor`) runs on.
        let indexService = LibrarySaveService.shared.indexService
        await indexService?.rebuild(itemsDirectory: dir)
    }

    /// The FIRST half of enabling encryption, split out so the Settings flow
    /// can show — and have the user acknowledge — the one-time recovery key
    /// BEFORE any file is touched (before-enable item (c)). Configures the
    /// vault with `password` and returns the one-time recovery key. Performs
    /// NO migration: on return the vault is configured + unlocked (`vault.json`
    /// written, DEK cached) but every Library file is still plaintext on disk.
    /// Call `runEnableMigration()` afterwards — only once the user has saved
    /// the key — to actually encrypt the files.
    ///
    /// `phase` is left untouched (stays `.idle`); the migration half owns the
    /// progress/failed phases. `configure`'s own overwrite guard means calling
    /// this against an already-configured vault throws `.malformed` without
    /// side effects.
    func configureVault(password: String) async throws -> String {
        let directory = itemsDirectory
        try await runOnIOQueue {
            _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
        guard await vault.state() == .notConfigured else { throw LibraryVaultError.malformed }
        let marker = disableMarkerURL
        try await runOnIOQueue {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard !names.contains(where: { ["m", "b", "x"].contains(($0 as NSString).pathExtension) }) else {
                throw LibraryEncryptionMigrator.MigrateError.incomplete
            }
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        }
        return try await vault.configure(password: password)
    }

    /// The SECOND half of enabling encryption: encrypts every plaintext item +
    /// aux file in place (materializing any evicted item's plaintext media from
    /// iCloud first — see `LibraryEncryptionMigrator.migrateAllMaterializing`),
    /// rebuilds the index, and lands `phase` on `.idle`.
    ///
    /// Idempotent / resumable: `migrateAllMaterializing` skips already-migrated
    /// items, so calling this again after a partial or failed run resumes where
    /// it stopped. It MUST NOT (and does not) call `vault.configure` again —
    /// the vault is already configured by `configureVault`, and `configure`'s
    /// overwrite guard would throw `.malformed`. Requires the vault to be
    /// unlocked (DEK cached), which `configureVault` leaves it.
    ///
    /// On any failure, `phase` becomes `.failed` and the error is rethrown,
    /// leaving every not-yet-reached item as untouched, resumable plaintext
    /// (see `LibraryEncryptionMigrator`'s crash-safety doc comment).
    func runEnableMigration() async throws {
        guard let crypto = await vault.crypto() else { throw LibraryVaultError.malformed }
        let migrator = LibraryEncryptionMigrator(itemsDirectory: itemsDirectory, crypto: crypto)

        do {
            phase = .encrypting(done: 0, total: 0)
            let marker = disableMarkerURL
            try await runOnIOQueue {
                guard !FileManager.default.fileExists(atPath: marker.path) else {
                    throw LibraryEncryptionMigrator.MigrateError.incomplete
                }
                try migrator.migrateAllMaterializing { done, total in
                    Task { @MainActor in
                        if case .encrypting = self.phase { self.phase = .encrypting(done: done, total: total) }
                    }
                }
                // Old plaintext journals contain item/album filenames. Drop them
                // only after conversion completes; encrypted stores don't use them.
                let names = try migrator.checkedContents()
                if names.contains(LibraryChangeJournal.directoryName) {
                    try FileManager.default.removeItem(at: migrator.itemsDirectory
                        .appendingPathComponent(LibraryChangeJournal.directoryName))
                }
            }

            await rebuildIndex()
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
    }

    /// True when the vault is configured (`state != .notConfigured`) AND
    /// plaintext items still await encryption (`pendingItemsAndAuxCount() > 0`)
    /// — i.e. a prior `enable`/`runEnableMigration` was interrupted, leaving
    /// the vault configured + unlocked with some files still plaintext. Drives
    /// the Settings "Resume" affordance. Returns false when not configured,
    /// when configured-but-locked (no cached DEK to build the migrator with —
    /// the user must unlock first), or when fully migrated.
    ///
    /// The pending-count check is a plain directory listing (no file reads, no
    /// crypto), routed through `ioQueue` rather than run on the main actor to
    /// keep with this app's no-blocking-work-on-MainActor discipline.
    func isEnableIncomplete() async -> Bool {
        let snapshot = await vault.snapshot()
        guard snapshot.state != .notConfigured, let crypto = snapshot.crypto else { return false }
        let directory = itemsDirectory
        let pending = await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                let migrator = LibraryEncryptionMigrator(itemsDirectory: directory, crypto: crypto)
                let names = try? migrator.checkedContents()
                let pending = (try? migrator.checkedPendingPlaintextCount()) ?? 1
                continuation.resume(returning: pending +
                    (names?.contains(LibraryChangeJournal.directoryName) == true ? 1 : 0))
            }
        }
        return pending > 0
    }

    /// Thin wrapper preserving the original one-call enable contract (used by
    /// the existing coordinator tests): configure the vault, then run the full
    /// migration, returning the recovery key only after both complete. The
    /// Settings UI instead calls `configureVault` and `runEnableMigration`
    /// separately so it can interpose the recovery-key acknowledgement between
    /// them.
    func enable(password: String) async throws -> String {
        let recovery = try await configureVault(password: password)
        try await runEnableMigration()
        return recovery
    }

    /// Turns encryption OFF: reverse-migrates every item + aux file back to
    /// plaintext (materializing any evicted item's ciphertext media — and,
    /// defensively, ciphertext sidecar/aux files — from iCloud first, see
    /// `LibraryEncryptionMigrator.decryptAllMaterializing`), and ONLY once
    /// that has fully completed — zero ciphertext remaining, per
    /// `decryptAll`'s hard completeness guarantee (it throws `.incomplete`
    /// rather than return non-throwing if anything survived) — tears down
    /// the vault, discarding the DEK.
    ///
    /// **This ordering is load-bearing.** If `vault.teardown()` ran before a
    /// fully-successful `decryptAll`, or if a partial/incomplete reverse
    /// migration were mistaken for success, the DEK needed to decrypt the
    /// still-remaining ciphertext would be gone for good — those items would
    /// be permanently unreadable. So teardown is reached ONLY on the
    /// non-throwing return path below; any throw from the migration step
    /// (including `.incomplete`) is caught, published as `.failed`, and
    /// rethrown WITHOUT tearing down — the vault stays configured and
    /// unlocked exactly as it was, so a retried `disable()` can finish the
    /// job with the same DEK.
    func disable() async throws {
        guard let crypto = await vault.crypto() else { throw LibraryVaultError.wrongCredential }
        let migrator = LibraryEncryptionMigrator(itemsDirectory: itemsDirectory, crypto: crypto)

        // Persist a "disable in progress" marker BEFORE the first file is
        // touched. `decryptAllMaterializing` restores items to plaintext one at
        // a time (verify-before-delete), so a crash/interruption partway leaves
        // the vault configured + unlocked with SOME plaintext already restored —
        // a state whose forward-pending (plaintext) count looks identical to an
        // interrupted ENABLE. This durable marker (next to `vault.json`) is what
        // lets `incompleteMigrationDirection()` tell the two apart and resume in
        // the DISABLE direction. Removed only on the success path below, so a
        // thrown/interrupted disable leaves it in place. Idempotent: a retried
        // disable() just rewrites it.
        do {
            phase = .decrypting(done: 0, total: 0)
            let marker = disableMarkerURL
            try await runOnIOQueue {
                _ = try migrator.checkedContents()
                // Failure to persist the direction must stop us BEFORE decryption.
                try Data("disabling".utf8).write(to: marker, options: .atomic)
                guard try Data(contentsOf: marker) == Data("disabling".utf8) else {
                    throw LibraryEncryptionMigrator.MigrateError.verifyFailed
                }
                try migrator.decryptAllMaterializing { done, total in
                    Task { @MainActor in
                        if case .decrypting = self.phase { self.phase = .decrypting(done: done, total: total) }
                    }
                }
                try migrator.verifyNoCiphertextRemains()
            }
            try await vault.teardown()
            try await runOnIOQueue { try FileManager.default.removeItem(at: marker) }
            await rebuildIndex()
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
    }

    // MARK: - Resume direction

    /// URL of the persisted "disable in progress" marker (a sibling of
    /// `vault.json`, see `LibraryVault.disableInProgressMarkerURL`).
    private var disableMarkerURL: URL { vault.disableInProgressMarkerURL }

    private func disableMarkerExists() -> Bool {
        FileManager.default.fileExists(atPath: disableMarkerURL.path)
    }

    /// The direction an interrupted migration should resume in, or `nil` when
    /// the container is clean/complete:
    ///
    ///  - `.disable` — the persisted "disable in progress" marker is present: a
    ///    reverse migration was interrupted (some items already back to
    ///    plaintext, the vault still configured + unlocked). Resuming MUST
    ///    continue decrypting, NOT re-encrypt the forward-pending plaintext.
    ///  - `.enable` — no marker, but the vault is configured and plaintext files
    ///    still await encryption (a partial/failed enable).
    ///  - `nil` — not configured, or fully migrated.
    ///
    /// The marker check is the disambiguator: mid-disable the forward-pending
    /// (plaintext) count is > 0 too, so `isEnableIncomplete()` alone would
    /// misclassify an interrupted disable as an interrupted enable. A single
    /// `fileExists` stat (not a directory walk) is cheap enough for the main
    /// actor; the `.enable` fallback's directory listing is offloaded by
    /// `isEnableIncomplete()`.
    func incompleteMigrationDirection() async -> LibraryMigrationDirection? {
        guard await vault.state() != .notConfigured else { return nil }
        if disableMarkerExists() { return .disable }
        return await isEnableIncomplete() ? .enable : nil
    }

    /// Runs a blocking migration call on `ioQueue` and suspends the caller
    /// until it finishes — without occupying a cooperative thread. Mirrors
    /// `LibraryFileMaterializer.runIO` / `LibraryImageRequest.runIO`.
    private func runOnIOQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
