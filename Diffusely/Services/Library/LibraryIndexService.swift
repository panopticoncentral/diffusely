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
        row.albumIDsJoined = PersistedLibraryItem.join(metadata.albumIDs)
    }

    func remove(itemID: Int) {
        if let existing = fetchItem(itemID: itemID) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    /// Batch-deletes index rows for the given ids in a single save. Used by the
    /// Library multi-select delete so removing N items is one persistence
    /// transaction instead of N. Unknown ids are skipped.
    func remove(itemIDs: [Int]) {
        guard !itemIDs.isEmpty else { return }
        var changed = false
        for itemID in itemIDs {
            if let existing = fetchItem(itemID: itemID) {
                modelContext.delete(existing)
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    // MARK: - Albums

    func upsertAlbum(id: UUID, name: String, createdAt: Date) {
        if let existing = fetchAlbum(id: id) {
            existing.name = name
            existing.createdAt = createdAt
        } else {
            modelContext.insert(PersistedAlbum(id: id, name: name, createdAt: createdAt))
        }
        try? modelContext.save()
    }

    func removeAlbum(id: UUID) {
        if let existing = fetchAlbum(id: id) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    /// Replaces an item row's membership. The sidecar is the source of truth and
    /// must already have been rewritten by the caller; this just keeps the index
    /// row in step without re-reading media or download status.
    func setAlbumIDs(itemID: Int, albumIDs: [String]) {
        guard let row = fetchItem(itemID: itemID) else { return }
        row.albumIDsJoined = PersistedLibraryItem.join(albumIDs)
        try? modelContext.save()
    }

    private func fetchAlbum(id: UUID) -> PersistedAlbum? {
        var d = FetchDescriptor<PersistedAlbum>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
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
    /// round-trip to the FileProvider daemon, blocking for a long time when a
    /// sidecar is a not-yet-materialized placeholder. The scan therefore runs on
    /// a dedicated serial queue (`scanQueue`), NOT `Task.detached`: a detached
    /// task runs on the Swift concurrency cooperative pool, and a blocking
    /// syscall there burns a cooperative thread. Overlapping reconciles (iCloud
    /// churn) would then block every cooperative thread at once and starve all
    /// `async` work app-wide — including image loading, which stranded the feed
    /// on permanent grey spinners. `withCheckedContinuation` suspends the caller
    /// without holding a cooperative thread, and the serial queue guarantees at
    /// most one blocked scan thread ever. Only the SwiftData writes below touch
    /// the model actor.
    func reconcile(itemsDirectory: URL) async {
        let scan = await Self.runScan(itemsDirectory: itemsDirectory)

        // A nil scan means the directory read *threw* (transient iCloud/filesystem
        // error). Treating that as "empty" would prune the whole index, so we
        // skip reconcile entirely and leave the index intact. A successfully-read
        // but empty directory still prunes normally — that's a legitimate
        // "every sidecar is gone" and the suite's reconcileDropsRowsWhoseSidecarVanished
        // depends on it.
        guard let scan else {
            print("[LibraryIndex] container unreadable; skipping reconcile to preserve the index")
            return
        }

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

    /// Upserts `PersistedAlbum` rows from the scan and prunes rows whose album
    /// file vanished. Pure in-memory work on the model context; caller saves.
    private func applyAlbums(_ scan: ScanResult) {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for file in scan.albums {
            if let row = byID[file.id] {
                row.name = file.name
                row.createdAt = file.createdAt
            } else {
                let row = PersistedAlbum(id: file.id, name: file.name, createdAt: file.createdAt)
                modelContext.insert(row)
                byID[file.id] = row
            }
        }
        for row in existing where !scan.seenAlbumIDs.contains(row.id) {
            modelContext.delete(row)
        }
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
        applyAlbums(scan)
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
        // Albums are applied and saved as one batch even in the per-item path; the
        // only failure mode (a duplicate id) is already prevented by applyAlbums's
        // dictionary guard, so per-row saves aren't needed here.
        applyAlbums(scan)
        if (try? modelContext.save()) == nil { modelContext.rollback() }
    }

    /// Reads the container off the model actor: walks the directory, reads and
    /// decodes every sidecar, and resolves each media file's download status.
    /// All blocking file I/O lives here, so it must only be called from a
    /// background task (never the main actor). `nonisolated` + `static` so it
    /// carries no actor isolation and the detached caller doesn't hop back.
    /// Result of an off-actor container scan: every readable sidecar paired with
    /// its media download status, plus the set of itemIDs seen (for pruning),
    /// plus every readable album file and the set of album ids seen (for album pruning).
    typealias ScanResult = (
        items: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)],
        seenIDs: Set<Int>,
        albums: [LibraryAlbumFile],
        seenAlbumIDs: Set<UUID>
    )

    /// Dedicated serial queue for the blocking container scan. Keeps the
    /// `Data(contentsOf:)` / FileProvider syscalls off the Swift concurrency
    /// cooperative pool (see `reconcile`). Serial, so overlapping reconciles
    /// can never block more than one thread.
    private static let scanQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.scan",
        qos: .utility
    )

    /// Runs `scanContainer` on `scanQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread.
    nonisolated static func runScan(itemsDirectory: URL) async -> ScanResult? {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: scanContainer(itemsDirectory: itemsDirectory))
            }
        }
    }

    nonisolated static func scanContainer(itemsDirectory: URL) -> ScanResult? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            // Couldn't read the directory (transient iCloud/filesystem error).
            // Returning an empty scan would make reconcile prune the entire
            // index; signal failure so the caller leaves it intact instead.
            return nil
        }

        let jsonURLs = contents.filter { $0.pathExtension == "json" }
        var seenIDs = Set<Int>()
        var items: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)] = []
        var albums: [LibraryAlbumFile] = []
        var seenAlbumIDs = Set<UUID>()

        for jsonURL in jsonURLs {
            let name = jsonURL.lastPathComponent

            // Album metadata file: decode separately, never as an item sidecar.
            if let albumID = LibraryAlbumStore.albumID(fromFileName: name) {
                // The file's presence means the album exists — mark it seen up
                // front so a present-but-unreadable file (placeholder, transient
                // read error, or corrupt JSON) never prunes the row. Mirrors how
                // a not-yet-materialized item is kept via seenIDs.
                seenAlbumIDs.insert(albumID)
                if isDatalessPlaceholder(jsonURL) {
                    try? fileManager.startDownloadingUbiquitousItem(at: jsonURL)
                    continue
                }
                // Decode best-effort: only a readable file refreshes name/createdAt.
                if let data = try? Data(contentsOf: jsonURL),
                   let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data) {
                    albums.append(file)
                }
                continue
            }

            // Item sidecar (existing behavior).
            // A sidecar whose bytes aren't materialized locally is an iCloud
            // placeholder; calling `Data(contentsOf:)` on it would force a
            // synchronous FileProvider download that can block for a long time.
            // Request a non-blocking download and preserve the item instead:
            // mark its ID seen so reconcile doesn't prune the row as "vanished",
            // and skip reading this round. A later reconcile (the metadata query
            // fires when the file materializes) ingests its fields.
            if isDatalessPlaceholder(jsonURL) {
                try? fileManager.startDownloadingUbiquitousItem(at: jsonURL)
                if let id = sidecarItemID(from: jsonURL) { seenIDs.insert(id) }
                continue
            }

            guard
                let data = try? Data(contentsOf: jsonURL),
                let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            else { continue }

            seenIDs.insert(metadata.itemID)
            let mediaURL = itemsDirectory.appendingPathComponent(metadata.mediaFileName)
            let status = downloadStatus(for: mediaURL, fileManager: fileManager)
            items.append((metadata: metadata, status: status))
        }
        return (items: items, seenIDs: seenIDs, albums: albums, seenAlbumIDs: seenAlbumIDs)
    }

    /// True when `url` is an iCloud item whose contents are not yet downloaded —
    /// reading it would force a blocking FileProvider materialization. Mirrors the
    /// status check in `downloadStatus(for:fileManager:)`. A non-ubiquitous local
    /// file returns `false` (safe to read directly).
    nonisolated static func isDatalessPlaceholder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard values?.isUbiquitousItem == true else { return false }
        switch values?.ubiquitousItemDownloadingStatus {
        case .some(.current), .some(.downloaded):
            return false   // bytes are present locally
        default:
            return true    // placeholder; not yet materialized
        }
    }

    /// Sidecars are named `{itemID}.json`, so the item ID is recoverable from the
    /// filename without reading the (possibly not-yet-downloaded) contents.
    nonisolated static func sidecarItemID(from jsonURL: URL) -> Int? {
        Int(jsonURL.deletingPathExtension().lastPathComponent)
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
        // Run every eviction on a dedicated serial queue (NOT `Task.detached`,
        // which stays on the Swift concurrency cooperative pool: a blocking
        // syscall there burns a cooperative thread and, under iCloud churn,
        // starves the pool — the documented "grey spinner" regression). The
        // queue also keeps the work off the model actor, which serializes all
        // index reads/writes, so a slow or unresponsive daemon can't wedge it
        // and beachball the whole app (it did, at ~1k items). Only the SwiftData
        // status flip below touches the actor.
        await Self.runEvictMediaFiles(fileNames: victimFiles, in: itemsDirectory)

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

    /// Dedicated serial queue for the blocking coordinated evictions below. Keeps
    /// the synchronous `NSFileCoordinator` + `FileManager.evictUbiquitousItem`
    /// syscalls (eviction is a blocking XPC round-trip to fileproviderd) off the
    /// Swift concurrency cooperative pool — running them on `Task.detached` or
    /// any `async` context would burn cooperative threads and starve the pool,
    /// the documented "grey spinner" regression. Serial + utility QoS mirrors
    /// `scanQueue` and `LibraryStore.deleteQueue`.
    private static let evictionQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.eviction",
        qos: .utility
    )

    /// Coordinates eviction of the named media files in `dir`. `nonisolated` so
    /// it carries no actor isolation; the synchronous file coordination must run
    /// on `evictionQueue`, never the main actor or the model actor. Missing files
    /// are tolerated (eviction is a no-op / swallowed error).
    nonisolated static func evictMediaFiles(fileNames: [String], in dir: URL) {
        let coordinator = NSFileCoordinator()
        for name in fileNames {
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
    }

    /// Runs `evictMediaFiles` on `evictionQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread or the model actor.
    nonisolated static func runEvictMediaFiles(fileNames: [String], in dir: URL) async {
        await withCheckedContinuation { continuation in
            evictionQueue.async {
                evictMediaFiles(fileNames: fileNames, in: dir)
                continuation.resume()
            }
        }
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
