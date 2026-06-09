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

    private static let queue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.album",
        qos: .utility
    )

    init(index: LibraryIndexService, itemsDirectory: @escaping () async -> URL?) {
        self.index = index
        self.resolveDirectory = itemsDirectory
    }

    // MARK: - Album lifecycle

    /// Creates an album and returns its id. Writes the album file first, then the
    /// index row — so a failed file write leaves no orphan index row that outlives
    /// a reconcile. Best-effort: file errors are not surfaced (reconcile is the
    /// backstop), consistent with the rest of the library file layer.
    @discardableResult
    func createAlbum(name: String) async -> UUID {
        let id = UUID()
        let file = LibraryAlbumFile(id: id, name: name, createdAt: Date())
        guard let dir = await resolveDirectory() else { return id }
        await Self.run { try? LibraryAlbumStore(itemsDirectory: dir).write(file) }
        await index.upsertAlbum(id: id, name: file.name, createdAt: file.createdAt)
        return id
    }

    func renameAlbum(_ id: UUID, to newName: String) async {
        guard let dir = await resolveDirectory() else { return }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        guard var file = await Self.run({ store.read(id: id) }) else { return }
        file.name = newName
        await Self.run { try? store.write(file) }
        await index.upsertAlbum(id: id, name: newName, createdAt: file.createdAt)
    }

    /// Deletes the album file and index row. Member items keep the now-dangling
    /// UUID in their sidecar indefinitely; there is no active cleanup. The id is
    /// harmless: every read path filters against the known-album set, so dangling
    /// ids are silently ignored. Media is never touched.
    func deleteAlbum(_ id: UUID) async {
        guard let dir = await resolveDirectory() else { return }
        await Self.run { LibraryAlbumStore(itemsDirectory: dir).delete(id: id) }
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
    private func mutateMembership(_ itemIDs: [Int], _ transform: @escaping ([String]) -> [String]) async {
        guard !itemIDs.isEmpty, let dir = await resolveDirectory() else { return }
        let writer = LibraryFileWriter(itemsDirectory: dir)
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
        for (itemID, ids) in updated {
            await index.setAlbumIDs(itemID: itemID, albumIDs: ids)
        }
    }

    /// Runs blocking file work on the dedicated serial queue and suspends the
    /// caller without holding a cooperative thread.
    private static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }
}
