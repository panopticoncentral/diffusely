import Foundation

/// Orchestrates album mutations: writes album files and item sidecars (the
/// sources of truth) and keeps the disposable index in step. All coordinated
/// file I/O runs on a dedicated serial queue, never the Swift-concurrency
/// cooperative pool — synchronous `NSFileCoordinator` calls there would burn
/// cooperative threads and, under iCloud churn, starve the pool (the documented
/// grey-spinner regression). Mirrors the queue discipline in `LibraryStore` and
/// `LibraryIndexService`.
///
/// `itemsDirectory` is a closure so production can resolve the iCloud container
/// lazily while tests inject a temp directory.
final class LibraryAlbumService {
    private let index: LibraryIndexService
    private let resolveDirectory: () async -> URL?
    /// Resolves the vault's current lock state and (when unlocked) its crypto.
    /// Defaults to the process-wide `LibraryVaultProvider.shared` singleton —
    /// the same source `LibraryIndexService.reconcile` reads — so production
    /// call sites need no change. Overridable so tests can drive `.locked`
    /// without touching the shared singleton (which would leak into every
    /// other test in the process; see `LibraryIndexEncryptedTests`).
    private let resolveVaultContext: () async -> (state: LibraryVault.State, crypto: LibraryFileCrypto?)

    private static let queue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.album",
        qos: .utility
    )

    init(
        index: LibraryIndexService,
        itemsDirectory: @escaping () async -> URL?,
        resolveVaultContext: @escaping () async -> (state: LibraryVault.State, crypto: LibraryFileCrypto?) = {
            let ctx = await LibraryVaultProvider.shared.reconcileContext()
            return (ctx.state, ctx.store.crypto)
        }
    ) {
        self.index = index
        self.resolveDirectory = itemsDirectory
        self.resolveVaultContext = resolveVaultContext
    }

    /// Atomic `(state, store)` pair for one operation: the resolved items
    /// directory merged with the vault's current lock state + crypto. In
    /// production both come from the same underlying container, so this
    /// always agrees with `LibraryVaultProvider.shared.fileStore()`; tests
    /// that inject their own directory are unaffected because the default
    /// `resolveVaultContext` stays `.notConfigured`/`crypto: nil` in a process
    /// that never configures the shared vault. `nil` only when the directory
    /// itself can't be resolved (unchanged pre-existing behavior).
    private func context() async -> (state: LibraryVault.State, store: LibraryFileStore)? {
        guard let dir = await resolveDirectory() else { return nil }
        let vault = await resolveVaultContext()
        return (vault.state, LibraryFileStore(itemsDirectory: dir, crypto: vault.crypto))
    }

    // MARK: - Album lifecycle

    /// Creates an album and returns its id. Writes the album file first, then the
    /// index row — so a failed file write leaves no orphan index row that outlives
    /// a reconcile. Best-effort: file errors are not surfaced (reconcile is the
    /// backstop), consistent with the rest of the library file layer. A locked
    /// vault is a no-op write (id is still returned, but nothing is persisted) —
    /// never write plaintext into an encrypted-but-locked container.
    @discardableResult
    func createAlbum(name: String) async -> UUID {
        let id = UUID()
        let file = LibraryAlbumFile(id: id, name: name, createdAt: Date())
        guard let ctx = await context(), ctx.state != .locked else { return id }
        await Self.run { try? LibraryAlbumStore(store: ctx.store).write(file) }
        await index.upsertAlbum(file)
        return id
    }

    func renameAlbum(_ id: UUID, to newName: String) async {
        await mutateAlbumFile(id) { $0.name = newName }
    }

    func setUserDescription(_ id: UUID, _ description: String?) async {
        await mutateAlbumFile(id) { $0.userDescription = description }
    }

    func setAIProfile(_ id: UUID, _ profile: AlbumAIProfile) async {
        await mutateAlbumFile(id) { $0.aiProfile = profile }
    }

    /// True when the album file exists in the container. Sort Assistant uses this
    /// to drop suggestions for albums deleted between classify and accept. Read-only,
    /// so it is not locked-guarded: a locked vault's store is a passthrough over
    /// opaque on-disk names, so it simply can't find the file and reads as absent.
    func albumExists(_ id: UUID) async -> Bool {
        guard let ctx = await context() else { return false }
        return await Self.run { LibraryAlbumStore(store: ctx.store).read(id: id) != nil }
    }

    /// Reads the album file, applies `mutate`, rewrites it, and refreshes the
    /// index row — file I/O on the dedicated serial queue (grey-spinner rule).
    /// Guard-skipped entirely while the vault is locked.
    private func mutateAlbumFile(_ id: UUID, _ mutate: @escaping (inout LibraryAlbumFile) -> Void) async {
        guard let ctx = await context(), ctx.state != .locked else { return }
        let store = LibraryAlbumStore(store: ctx.store)
        guard var file = await Self.run({ store.read(id: id) }) else { return }
        mutate(&file)
        await Self.run { try? store.write(file) }
        await index.upsertAlbum(file)
    }

    /// Deletes the album file and index row. Member items keep the now-dangling
    /// UUID in their sidecar indefinitely; there is no active cleanup. The id is
    /// harmless: every read path filters against the known-album set, so dangling
    /// ids are silently ignored. Media is never touched. Guard-skipped while locked.
    func deleteAlbum(_ id: UUID) async {
        guard let ctx = await context(), ctx.state != .locked else { return }
        await Self.run { LibraryAlbumStore(store: ctx.store).delete(id: id) }
        await index.removeAlbum(id: id)
    }

    // MARK: - Membership

    func addItems(_ itemIDs: [Int], toAlbum id: UUID) async {
        await mutateMembership(itemIDs) { current in
            current.contains(id.uuidString) ? current : current + [id.uuidString]
        }
    }

    func removeItems(_ itemIDs: [Int], fromAlbum id: UUID) async {
        await mutateMembership(itemIDs) { current in
            current.filter { $0 != id.uuidString }
        }
    }

    /// Reads each item's sidecar, applies `transform` to its album list, rewrites
    /// the sidecar, and updates the index row — all off the cooperative pool.
    /// Guard-skipped entirely while the vault is locked.
    private func mutateMembership(_ itemIDs: [Int], _ transform: @escaping ([String]) -> [String]) async {
        guard !itemIDs.isEmpty, let ctx = await context(), ctx.state != .locked else { return }
        let writer = LibraryFileWriter(store: ctx.store)
        let updated: [(Int, [String])] = await Self.run {
            var results: [(Int, [String])] = []
            for itemID in itemIDs {
                guard let meta = writer.readMetadata(itemID: itemID) else { continue }
                let newIDs = transform(meta.albumIDs)
                guard newIDs != meta.albumIDs else { continue }   // already in desired state — nothing to do
                // The sidecar is the source of truth: only record the new ids for
                // the index once the file rewrite actually succeeded. On failure we
                // leave both file and index untouched (the next reconcile re-derives
                // membership from the sidecar anyway).
                guard (try? writer.rewriteMetadata(meta.settingAlbumIDs(newIDs))) != nil else { continue }
                results.append((itemID, newIDs))
            }
            return results
        }
        // One batched index update (single epoch bump + single save) so a
        // large accept doesn't serialize N saves against the main thread's
        // fetches on the shared store.
        await index.setAlbumIDs(updated.map { (itemID: $0.0, albumIDs: $0.1) })
    }

    /// Runs blocking file work on the dedicated serial queue and suspends the
    /// caller without holding a cooperative thread.
    private static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }
}
