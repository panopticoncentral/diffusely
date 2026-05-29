import Foundation
import SwiftData

/// Owns all writes to the disposable `PersistedLibraryItem` index. The container
/// (media + sidecar JSON) is the source of truth; this index is rebuilt from it on
/// launch and whenever iCloud reports changes, and can be wiped and regenerated at
/// any time without data loss.
@ModelActor
actor LibraryIndexService {

    // MARK: - Upsert

    func ingest(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
        if let existing = fetchItem(itemID: metadata.itemID) {
            apply(metadata, downloadStatus: downloadStatus, to: existing)
        } else {
            modelContext.insert(PersistedLibraryItem(metadata: metadata, downloadStatus: downloadStatus))
        }
        try? modelContext.save()
    }

    /// Copies the mutable fields from a freshly-read sidecar onto an existing
    /// index row. Pure in-memory work — no fetch, no save.
    private func apply(
        _ metadata: LibraryItemMetadata,
        downloadStatus: LibraryDownloadStatus,
        to row: PersistedLibraryItem
    ) {
        row.mediaType = metadata.mediaType.rawValue
        row.mediaFileName = metadata.mediaFileName
        row.width = metadata.width
        row.height = metadata.height
        row.nsfwLevel = metadata.nsfwLevel
        row.authorUsername = metadata.author.username
        row.authorAvatarURL = metadata.author.avatarURL
        row.sourcePostID = metadata.sourcePostID
        row.canonicalPageURL = metadata.canonicalPageURL
        row.fileByteSize = metadata.fileByteSize
        row.savedAt = metadata.savedAt
        row.publishedAt = metadata.publishedAt
        row.needsDateBackfill = PersistedLibraryItem.computeNeedsDateBackfill(for: metadata)
        row.checkpointName = metadata.generationData?
            .resources?
            .first(where: { $0.modelType == "Checkpoint" })?
            .modelName
        row.downloadStatus = downloadStatus
    }

    func remove(itemID: Int) {
        if let existing = fetchItem(itemID: itemID) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    func recordAccess(itemID: Int, status: LibraryDownloadStatus? = nil) {
        guard let existing = fetchItem(itemID: itemID) else { return }
        existing.lastAccessedAt = Date()
        if let status { existing.downloadStatus = status }
        try? modelContext.save()
    }

    func setStatus(itemID: Int, status: LibraryDownloadStatus) {
        guard let existing = fetchItem(itemID: itemID) else { return }
        existing.downloadStatus = status
        try? modelContext.save()
    }

    func currentDownloadStatus(itemID: Int) -> LibraryDownloadStatus? {
        fetchItem(itemID: itemID)?.downloadStatus
    }

    // MARK: - Reconcile (container -> index)

    /// Diffs the container against the index: ingests every readable sidecar
    /// (including ones synced from other devices), drops rows whose sidecar
    /// vanished, and ignores media without a committed JSON.
    ///
    /// The directory walk, per-sidecar `Data(contentsOf:)` reads, and per-media
    /// iCloud status lookups are all blocking syscalls — and the iCloud ones
    /// round-trip to the FileProvider daemon. They ran on the main thread for a
    /// full library on launch and froze the UI (beachball), so the scan is now
    /// done on a detached background task; only the SwiftData writes touch the
    /// model actor.
    func reconcile(itemsDirectory: URL) async {
        let scan = await Task.detached(priority: .utility) {
            Self.scanContainer(itemsDirectory: itemsDirectory)
        }.value

        // Fast path: upsert everything from an in-memory map and save once
        // (one query + one save instead of N + N). If that batched save throws,
        // fall back to a resilient per-item pass — a single all-or-nothing save
        // that silently failed is exactly what stranded the whole index empty
        // after a rebuild, so one poison row must never lose the other 1024.
        if reconcileBatched(scan) { return }
        print("[LibraryIndex] batched reconcile save failed; retrying per-item")
        modelContext.rollback()
        reconcilePerItem(scan)
    }

    /// One in-memory diff + a single batched save. Returns `true` on success.
    private func reconcileBatched(_ scan: ScanResult) -> Bool {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var byID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        for (metadata, status) in scan.items {
            if let row = byID[metadata.itemID] {
                apply(metadata, downloadStatus: status, to: row)
            } else {
                let row = PersistedLibraryItem(metadata: metadata, downloadStatus: status)
                modelContext.insert(row)
                byID[metadata.itemID] = row
            }
        }
        for item in existing where !scan.seenIDs.contains(item.itemID) {
            modelContext.delete(item)
        }
        do {
            try modelContext.save()
            return true
        } catch {
            print("[LibraryIndex] batched reconcile save threw (\(scan.items.count) sidecars): \(error)")
            return false
        }
    }

    /// Slow, resilient recovery: save after every row so a single bad sidecar
    /// (or a constraint hiccup) is rolled back and skipped instead of taking the
    /// entire batch down with it. Only runs when the fast path's save failed.
    private func reconcilePerItem(_ scan: ScanResult) {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var byID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        for item in existing where !scan.seenIDs.contains(item.itemID) {
            modelContext.delete(item)
            if (try? modelContext.save()) == nil { modelContext.rollback() }
        }
        for (metadata, status) in scan.items {
            if let row = byID[metadata.itemID] {
                apply(metadata, downloadStatus: status, to: row)
            } else {
                let row = PersistedLibraryItem(metadata: metadata, downloadStatus: status)
                modelContext.insert(row)
                byID[metadata.itemID] = row
            }
            do {
                try modelContext.save()
            } catch {
                print("[LibraryIndex] skipping item \(metadata.itemID): \(error)")
                modelContext.rollback()
            }
        }
    }

    /// Reads the container off the model actor: walks the directory, reads and
    /// decodes every sidecar, and resolves each media file's download status.
    /// All blocking file I/O lives here, so it must only be called from a
    /// background task (never the main actor). `nonisolated` + `static` so it
    /// carries no actor isolation and the detached caller doesn't hop back.
    /// Result of an off-actor container scan: every readable sidecar paired with
    /// its media download status, plus the set of itemIDs seen (for pruning).
    typealias ScanResult = (
        items: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)],
        seenIDs: Set<Int>
    )

    nonisolated static func scanContainer(itemsDirectory: URL) -> ScanResult {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let jsonURLs = contents.filter { $0.pathExtension == "json" }
        var seenIDs = Set<Int>()
        var items: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)] = []

        for jsonURL in jsonURLs {
            guard
                let data = try? Data(contentsOf: jsonURL),
                let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            else { continue }

            seenIDs.insert(metadata.itemID)
            let mediaURL = itemsDirectory.appendingPathComponent(metadata.mediaFileName)
            let status = downloadStatus(for: mediaURL, fileManager: fileManager)
            items.append((metadata: metadata, status: status))
        }
        return (items: items, seenIDs: seenIDs)
    }

    /// Rebuilds the index from the container. Despite the name this no longer
    /// wipes-then-reinserts: deleting every row and immediately re-inserting new
    /// objects with the *same* `@Attribute(.unique) itemID` values on this one
    /// `@ModelActor` context (within the same session) made the re-insert `save()`
    /// throw a unique-constraint violation — the uniquing index still carried the
    /// just-deleted keys — which `try?` then swallowed, stranding the store empty.
    /// `reconcile` already re-reads every sidecar, re-applies all mutable fields
    /// (healing field-level corruption), inserts brand-new sidecars, and deletes
    /// rows whose sidecar has vanished. That is a full rebuild from the source of
    /// truth, without the destructive empty window or the re-insert hazard.
    func rebuild(itemsDirectory: URL) async {
        await reconcile(itemsDirectory: itemsDirectory)
    }

    /// Deletes every index row without reconciling. Used by Reset Library after
    /// the container files themselves have been deleted.
    func wipe() {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        for item in existing { modelContext.delete(item) }
        try? modelContext.save()
    }

    func itemCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PersistedLibraryItem>())) ?? 0
    }

    // MARK: - LRU eviction

    func totalDownloadedBytes() -> Int {
        let items = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        return items
            .filter { $0.downloadStatus == .downloaded }
            .reduce(0) { $0 + $1.fileByteSize }
    }

    /// Evicts least-recently-accessed media until the downloaded total is at or
    /// below `maxBytes`. Sidecar JSON is never evicted. Cooperative, not exact -
    /// iCloud may also evict independently.
    func enforceCacheLimit(maxBytes: Int, itemsDirectory: URL) async {
        guard maxBytes > 0 else { return }
        let downloaded = ((try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? [])
            .filter { $0.downloadStatus == .downloaded }
        var total = downloaded.reduce(0) { $0 + $1.fileByteSize }
        guard total > maxBytes else { return }

        // Pick least-recently-accessed victims down to the limit. Pure read of
        // index state — we only need the filenames for the file I/O below.
        var victimIDs: [Int] = []
        var victimFiles: [String] = []
        for item in downloaded.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            if total <= maxBytes { break }
            victimIDs.append(item.itemID)
            victimFiles.append(item.mediaFileName)
            total -= item.fileByteSize
        }
        guard !victimIDs.isEmpty else { return }

        // `evictUbiquitousItem` is a blocking XPC round-trip to fileproviderd.
        // Run every eviction on a detached task so a slow or unresponsive daemon
        // can't wedge the model actor — which serializes all index reads/writes
        // — and beachball the whole app (it did, at ~1k items). Only the
        // SwiftData status flip below touches the actor.
        let dir = itemsDirectory
        let files = victimFiles
        await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator()
            for name in files {
                let mediaURL = dir.appendingPathComponent(name)
                var coordinationError: NSError?
                coordinator.coordinate(
                    writingItemAt: mediaURL,
                    options: .forDeleting,
                    error: &coordinationError
                ) { url in
                    try? FileManager.default.evictUbiquitousItem(at: url)
                }
            }
        }.value

        // Re-fetch after the suspension (the actor is reentrant — another call
        // may have run while we awaited), then flip the evicted rows and save
        // once.
        let evicted = Set(victimIDs)
        let rows = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        for item in rows where evicted.contains(item.itemID) {
            item.downloadStatus = .evicted
        }
        try? modelContext.save()
    }

    func evictAllDownloaded(itemsDirectory: URL) async {
        await enforceCacheLimit(maxBytes: 1, itemsDirectory: itemsDirectory)
    }

    // MARK: - Helpers

    private func fetchItem(itemID: Int) -> PersistedLibraryItem? {
        var descriptor = FetchDescriptor<PersistedLibraryItem>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    static func downloadStatus(for mediaURL: URL, fileManager: FileManager) -> LibraryDownloadStatus {
        guard fileManager.fileExists(atPath: mediaURL.path) else {
            // No local placeholder at all - treat as evicted; on-demand download
            // will materialize it when the user opens the item.
            return .evicted
        }
        let values = try? mediaURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        if values?.isUbiquitousItem == true {
            switch values?.ubiquitousItemDownloadingStatus {
            case .some(.current), .some(.downloaded):
                return .downloaded
            default:
                return .evicted
            }
        }
        // Non-ubiquitous local file (local-only fallback) that exists = downloaded.
        return .downloaded
    }
}
