import Foundation
import SwiftData

/// Owns all writes to the disposable `PersistedLibraryItem` index. The container
/// (media + sidecar JSON) is the source of truth; this index is rebuilt from it on
/// launch and whenever iCloud reports changes, and can be wiped and regenerated at
/// any time without data loss.
@ModelActor
actor LibraryIndexService {

    // MARK: - Mutation epoch

    /// Monotonic count of direct index mutations (ingests, deletes, album
    /// rows, membership changes). A reconcile captures it before scanning and
    /// only applies the scan if it hasn't moved — the fence that stops a
    /// stale container snapshot from overwriting newer rows (the
    /// "items reappear in Not in any Album" bug).
    private var mutationEpoch = 0

    func currentMutationEpoch() -> Int { mutationEpoch }

    /// Every mutator whose effect a stale scan could wrongly undo calls this
    /// on entry — unconditional (even if the mutation turns out to be a no-op):
    /// cheap, and a false-positive rescan is harmless while a missed bump is
    /// the clobber bug. `recordAccess`/`setStatus`/`enforceCacheLimit` are
    /// deliberately excluded: they change only ephemeral fields (last access,
    /// download status) that the next reconcile re-derives anyway, and they
    /// fire often enough to starve reconcile's bounded rescan loop.
    private func bumpMutationEpoch() { mutationEpoch += 1 }

    /// Outcome of applying a container scan to the index.
    enum ScanApplication: Equatable {
        /// A direct write landed after the scan's epoch was captured; the stale
        /// snapshot was rejected and the caller should rescan.
        case rejectedStaleEpoch
        /// The scan was applied. `albumStateChanged` is true when it altered
        /// album rows or any item's membership — UI that renders album state
        /// won't see those edits through `itemCount` and must be reloaded.
        case applied(albumStateChanged: Bool)

        var wasApplied: Bool { self != .rejectedStaleEpoch }
    }

    // MARK: - Upsert

    func ingest(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
        bumpMutationEpoch()
        if let existing = fetchItem(itemID: metadata.itemID) {
            apply(metadata, downloadStatus: downloadStatus, to: existing)
        } else {
            modelContext.insert(PersistedLibraryItem(metadata: metadata, downloadStatus: downloadStatus))
        }
        try? modelContext.save()
    }

    /// Copies the mutable fields from a freshly-read sidecar onto an existing
    /// index row. Pure in-memory work — no fetch, no save. Returns whether the
    /// row's album membership changed, so reconcile can signal album-observing UI.
    @discardableResult
    private func apply(
        _ metadata: LibraryItemMetadata,
        downloadStatus: LibraryDownloadStatus,
        to row: PersistedLibraryItem
    ) -> Bool {
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
        let newAlbumIDsJoined = PersistedLibraryItem.join(metadata.albumIDs)
        let membershipChanged = row.albumIDsJoined != newAlbumIDsJoined
        row.albumIDsJoined = newAlbumIDsJoined
        return membershipChanged
    }

    func remove(itemID: Int) {
        bumpMutationEpoch()
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
        bumpMutationEpoch()
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

    func upsertAlbum(_ file: LibraryAlbumFile) {
        bumpMutationEpoch()
        if let existing = fetchAlbum(id: file.id) {
            Self.apply(file, to: existing)
        } else {
            modelContext.insert(PersistedAlbum(file: file))
        }
        try? modelContext.save()
    }

    /// Copies all denormalized fields from an album file onto an index row.
    /// Returns whether anything observable changed (drives the albumsVersion
    /// reload signal).
    @discardableResult
    private static func apply(_ file: LibraryAlbumFile, to row: PersistedAlbum) -> Bool {
        let changed = row.name != file.name || row.createdAt != file.createdAt
            || row.userDescription != file.userDescription
            || row.aiProfileText != file.aiProfile?.text
            || row.aiProfileBuiltAt != file.aiProfile?.builtAt
            || row.aiProfileMemberCount != (file.aiProfile?.memberCount ?? 0)
        row.name = file.name
        row.createdAt = file.createdAt
        row.userDescription = file.userDescription
        row.aiProfileText = file.aiProfile?.text
        row.aiProfileBuiltAt = file.aiProfile?.builtAt
        row.aiProfileMemberCount = file.aiProfile?.memberCount ?? 0
        return changed
    }

    func removeAlbum(id: UUID) {
        bumpMutationEpoch()
        if let existing = fetchAlbum(id: id) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    /// Replaces an item row's membership. The sidecar is the source of truth and
    /// must already have been rewritten by the caller; this just keeps the index
    /// row in step without re-reading media or download status.
    func setAlbumIDs(itemID: Int, albumIDs: [String]) {
        setAlbumIDs([(itemID, albumIDs)])
    }

    /// Batch variant: one mutation epoch and ONE save for the whole update.
    /// Accepting a large Sort Assistant group was N per-item saves, and the
    /// main thread's own fetches contend with each one on the shared SQLite
    /// store — visible as beachballs during accepts.
    func setAlbumIDs(_ updates: [(itemID: Int, albumIDs: [String])]) {
        guard !updates.isEmpty else { return }
        bumpMutationEpoch()
        var changed = false
        for (itemID, albumIDs) in updates {
            guard let row = fetchItem(itemID: itemID) else { continue }
            row.albumIDsJoined = PersistedLibraryItem.join(albumIDs)
            changed = true
        }
        if changed { try? modelContext.save() }
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
    /// Returns whether the reconcile changed album-relevant state (album rows or
    /// item membership) — those edits are invisible to `itemCount`, so the caller
    /// must signal album-observing UI when this is true. A skipped reconcile
    /// (unreadable container, or direct writes kept landing) returns false: the
    /// metadata query re-fires for every container change, so a follow-up
    /// reconcile reports the change instead.
    @discardableResult
    func reconcile(itemsDirectory: URL) async -> Bool {
        // The scan is a point-in-time snapshot of the container, read off the
        // actor. Direct mutations (add-to-album, saves, deletes) can land while
        // it is in flight; applying the snapshot then would overwrite the newer
        // index rows with pre-mutation data — e.g. resurrecting just-filed items
        // in "Not in any Album" until the next reconcile healed them. Capture
        // the mutation epoch before each scan and rescan if it moved. Bounded:
        // every epoch bump corresponds to a container file change, which
        // re-fires the metadata query and schedules another reconcile, so
        // giving up here never strands the index.
        for _ in 0..<3 {
            let epoch = currentMutationEpoch()
            let scan = await Self.runScan(itemsDirectory: itemsDirectory)

            // A nil scan means the directory read *threw* (transient iCloud/filesystem
            // error). Treating that as "empty" would prune the whole index, so we
            // skip reconcile entirely and leave the index intact. A successfully-read
            // but empty directory still prunes normally — that's a legitimate
            // "every sidecar is gone" and the suite's reconcileDropsRowsWhoseSidecarVanished
            // depends on it.
            guard let scan else {
                print("[LibraryIndex] container unreadable; skipping reconcile to preserve the index")
                return false
            }

            if case .applied(let albumStateChanged) = applyScan(scan, ifEpochMatches: epoch) {
                return albumStateChanged
            }
            print("[LibraryIndex] direct write landed during the container scan; rescanning")
        }
        print("[LibraryIndex] reconcile skipped: direct writes kept landing during scans")
        return false
    }

    /// Applies a completed scan to the index — unless a direct mutation landed
    /// after `epoch` was captured, in which case the snapshot is stale and is
    /// rejected (`.rejectedStaleEpoch`; the caller rescans). Internal rather than
    /// private so tests can drive the write-during-scan race deterministically.
    func applyScan(_ scan: ScanResult, ifEpochMatches epoch: Int) -> ScanApplication {
        guard currentMutationEpoch() == epoch else { return .rejectedStaleEpoch }

        // Fast path: upsert everything from an in-memory map and save once
        // (one query + one save instead of N + N). If that batched save throws,
        // fall back to a resilient per-item pass — a single all-or-nothing save
        // that silently failed is exactly what stranded the whole index empty
        // after a rebuild, so one poison row must never lose the other 1024.
        if let albumStateChanged = reconcileBatched(scan) {
            return .applied(albumStateChanged: albumStateChanged)
        }
        print("[LibraryIndex] batched reconcile save failed; retrying per-item")
        modelContext.rollback()
        return .applied(albumStateChanged: reconcilePerItem(scan))
    }

    /// Upserts `PersistedAlbum` rows from the scan and prunes rows whose album
    /// file vanished. Pure in-memory work on the model context; caller saves.
    /// Returns whether any album row was inserted, updated, or deleted.
    private func applyAlbums(_ scan: ScanResult) -> Bool {
        var changed = false
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for file in scan.albums {
            if let row = byID[file.id] {
                if Self.apply(file, to: row) { changed = true }
            } else {
                let row = PersistedAlbum(file: file)
                modelContext.insert(row)
                byID[file.id] = row
                changed = true
            }
        }
        for row in existing where !scan.seenAlbumIDs.contains(row.id) {
            modelContext.delete(row)
            changed = true
        }
        return changed
    }

    /// One in-memory diff + a single batched save. Returns whether album-relevant
    /// state changed on success, or `nil` if the save failed.
    private func reconcileBatched(_ scan: ScanResult) -> Bool? {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var byID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        var albumStateChanged = false
        for (metadata, status) in scan.items {
            if let row = byID[metadata.itemID] {
                if apply(metadata, downloadStatus: status, to: row) { albumStateChanged = true }
            } else {
                let row = PersistedLibraryItem(metadata: metadata, downloadStatus: status)
                modelContext.insert(row)
                byID[metadata.itemID] = row
                if !metadata.albumIDs.isEmpty { albumStateChanged = true }
            }
        }
        for item in existing where !scan.seenIDs.contains(item.itemID) {
            if !item.albumIDsJoined.isEmpty { albumStateChanged = true }
            modelContext.delete(item)
        }
        if applyAlbums(scan) { albumStateChanged = true }
        do {
            try modelContext.save()
            return albumStateChanged
        } catch {
            print("[LibraryIndex] batched reconcile save threw (\(scan.items.count) sidecars): \(error)")
            return nil
        }
    }

    /// Slow, resilient recovery: save after every row so a single bad sidecar
    /// (or a constraint hiccup) is rolled back and skipped instead of taking the
    /// entire batch down with it. Only runs when the fast path's save failed.
    /// Returns whether album-relevant state changed (same contract as
    /// `reconcileBatched`'s success case).
    private func reconcilePerItem(_ scan: ScanResult) -> Bool {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var byID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        var albumStateChanged = false
        for item in existing where !scan.seenIDs.contains(item.itemID) {
            if !item.albumIDsJoined.isEmpty { albumStateChanged = true }
            modelContext.delete(item)
            if (try? modelContext.save()) == nil { modelContext.rollback() }
        }
        for (metadata, status) in scan.items {
            let membershipChanged: Bool
            if let row = byID[metadata.itemID] {
                membershipChanged = apply(metadata, downloadStatus: status, to: row)
            } else {
                let row = PersistedLibraryItem(metadata: metadata, downloadStatus: status)
                modelContext.insert(row)
                byID[metadata.itemID] = row
                membershipChanged = !metadata.albumIDs.isEmpty
            }
            do {
                try modelContext.save()
                if membershipChanged { albumStateChanged = true }
            } catch {
                print("[LibraryIndex] skipping item \(metadata.itemID): \(error)")
                modelContext.rollback()
            }
        }
        // Albums are applied and saved as one batch even in the per-item path; the
        // only failure mode (a duplicate id) is already prevented by applyAlbums's
        // dictionary guard, so per-row saves aren't needed here.
        let albumRowsChanged = applyAlbums(scan)
        if (try? modelContext.save()) == nil {
            modelContext.rollback()
        } else if albumRowsChanged {
            albumStateChanged = true
        }
        return albumStateChanged
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

    /// Resource keys prefetched during directory enumeration so the per-file
    /// ubiquitous-status reads (`isDatalessPlaceholder`, `downloadStatus`) are
    /// served from the enumerated URL objects' caches. Without the prefetch,
    /// every `resourceValues` call is an individual blocking XPC round-trip to
    /// fileproviderd — ~13k per scan at a 6.5k-item library, which turned the
    /// launch reconcile into minutes of churn on macOS.
    nonisolated static let scanPrefetchKeys: [URLResourceKey] = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    nonisolated static func scanContainer(itemsDirectory: URL) -> ScanResult? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: scanPrefetchKeys
        ) else {
            // Couldn't read the directory (transient iCloud/filesystem error).
            // Returning an empty scan would make reconcile prune the entire
            // index; signal failure so the caller leaves it intact instead.
            return nil
        }

        // Media files are looked up from the same enumeration: the returned
        // URL objects carry the prefetched status values, while a freshly
        // built `appendingPathComponent` URL has an empty cache and would XPC
        // to fileproviderd per file. Cached values are point-in-time, which is
        // exactly the snapshot semantics a scan wants; each scan re-enumerates
        // and gets fresh objects.
        var urlsByName = [String: URL](minimumCapacity: contents.count)
        for url in contents { urlsByName[url.lastPathComponent] = url }

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
            // Missing from the listing (no local placeholder at all) falls back
            // to a built URL, which `downloadStatus` resolves to `.evicted` via
            // its fileExists check — same result as before, no XPC needed.
            let mediaURL = urlsByName[metadata.mediaFileName]
                ?? itemsDirectory.appendingPathComponent(metadata.mediaFileName)
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
    @discardableResult
    func rebuild(itemsDirectory: URL) async -> Bool {
        await reconcile(itemsDirectory: itemsDirectory)
    }

    /// Deletes every index row without reconciling. Used by Reset Library after
    /// the container files themselves have been deleted.
    func wipe() {
        bumpMutationEpoch()
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
