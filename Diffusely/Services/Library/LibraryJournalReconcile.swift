import Foundation
import Darwin

extension LibraryIndexService {
    struct JournalBaseline {
        var snapshot: LibraryChangeJournal.Snapshot
        var auditedAt: Date
    }

    /// Full audits discover files written by other applications or older clients.
    static let journalAuditInterval: TimeInterval = 300

    func reconcileJournalChanges(
        journal: LibraryChangeJournal, snapshot: LibraryChangeJournal.Snapshot,
        key: String, store: LibraryFileStore, epoch: Int, startedAtGeneration: Int,
        generationProbe: @Sendable @escaping () async -> Int
    ) async -> ReconcileOutcome? {
        guard let baseline = journalBaselines[key],
              Date().timeIntervalSince(baseline.auditedAt) < Self.journalAuditInterval,
              let names = snapshot.changes(since: baseline.snapshot), names.count <= 512 else { return nil }
        // A media change refreshes the corresponding metadata row/status too.
        let sidecars = Set(names.compactMap { name -> String? in
            if LibraryAlbumStore.albumID(fromFileName: name) != nil { return name }
            let stem = (name as NSString).deletingPathExtension
            return Int(stem) == nil ? nil : stem + ".json"
        })
        let delta = await Self.scanIO { () -> (ScanResult, Set<Int>, Set<UUID>)? in
            var urls: [URL] = []
            var deletedItems = Set<Int>()
            var deletedAlbums = Set<UUID>()
            for name in sidecars.sorted() {
                let url = store.itemsDirectory.appendingPathComponent(name)
                var info = stat()
                if lstat(url.path, &info) == 0 { urls.append(url) }
                else if errno == ENOENT {
                    if let id = LibraryAlbumStore.albumID(fromFileName: name) { deletedAlbums.insert(id) }
                    else if let id = Int(url.deletingPathExtension().lastPathComponent) { deletedItems.insert(id) }
                } else { return nil } // EIO/EACCES are never evidence of deletion.
            }
            guard let scan = Self.scanContainer(store: store, listedContents: urls) else { return nil }
            // A vanished mount can make EVERY child look absent. Validate the
            // root again before accepting individual ENOENT results.
            guard (try? store.itemsDirectory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return (scan, deletedItems, deletedAlbums)
        }
        guard let delta else { return nil }
        let after = await Self.scanIO { try? journal.snapshot() }
        guard after == snapshot, await generationProbe() == startedAtGeneration,
              currentMutationEpoch() == epoch, !Task.isCancelled else { return nil }
        guard let changed = reconcileBatched(delta.0, pruneMissing: false,
            deletedItemIDs: delta.1, deletedAlbumIDs: delta.2) else {
            modelContext.rollback()
            return nil
        }
        journalBaselines[key] = JournalBaseline(snapshot: snapshot, auditedAt: baseline.auditedAt)
        print("[LibraryIndex] journal refresh: \(sidecars.count) sidecars; full directory scan skipped")
        // A partial change set cannot establish the whole placeholder backlog
        // (a custom folder can itself be managed by a cloud provider).
        return ReconcileOutcome(albumStateChanged: changed, sidecarsRead: delta.0.metrics.sidecarsRead)
    }
}
