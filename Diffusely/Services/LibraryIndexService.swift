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
        let id = metadata.itemID
        if let existing = fetchItem(itemID: id) {
            existing.mediaType = metadata.mediaType.rawValue
            existing.mediaFileName = metadata.mediaFileName
            existing.width = metadata.width
            existing.height = metadata.height
            existing.nsfwLevel = metadata.nsfwLevel
            existing.authorUsername = metadata.author.username
            existing.sourcePostID = metadata.sourcePostID
            existing.canonicalPageURL = metadata.canonicalPageURL
            existing.fileByteSize = metadata.fileByteSize
            existing.savedAt = metadata.savedAt
            existing.downloadStatus = downloadStatus
        } else {
            modelContext.insert(PersistedLibraryItem(metadata: metadata, downloadStatus: downloadStatus))
        }
        try? modelContext.save()
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

    // MARK: - Reconcile (container -> index)

    /// Diffs the container against the index: ingests every readable sidecar
    /// (including ones synced from other devices), drops rows whose sidecar
    /// vanished, and ignores media without a committed JSON.
    func reconcile(itemsDirectory: URL) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let jsonURLs = contents.filter { $0.pathExtension == "json" }
        var seenIDs = Set<Int>()

        for jsonURL in jsonURLs {
            guard
                let data = try? Data(contentsOf: jsonURL),
                let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            else { continue }

            seenIDs.insert(metadata.itemID)
            let mediaURL = itemsDirectory.appendingPathComponent(metadata.mediaFileName)
            let status = Self.downloadStatus(for: mediaURL, fileManager: fileManager)
            ingest(metadata: metadata, downloadStatus: status)
        }

        // Drop rows whose sidecar no longer exists.
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        for item in existing where !seenIDs.contains(item.itemID) {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    func rebuild(itemsDirectory: URL) {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        for item in existing { modelContext.delete(item) }
        try? modelContext.save()
        reconcile(itemsDirectory: itemsDirectory)
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
    func enforceCacheLimit(maxBytes: Int, itemsDirectory: URL) {
        guard maxBytes > 0 else { return }
        var items = ((try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? [])
            .filter { $0.downloadStatus == .downloaded }
        var total = items.reduce(0) { $0 + $1.fileByteSize }
        guard total > maxBytes else { return }

        items.sort { $0.lastAccessedAt < $1.lastAccessedAt }
        let coordinator = NSFileCoordinator()
        for item in items {
            if total <= maxBytes { break }
            let mediaURL = itemsDirectory.appendingPathComponent(item.mediaFileName)
            var coordinationError: NSError?
            coordinator.coordinate(
                writingItemAt: mediaURL,
                options: .forDeleting,
                error: &coordinationError
            ) { url in
                try? FileManager.default.evictUbiquitousItem(at: url)
            }
            item.downloadStatus = .evicted
            total -= item.fileByteSize
        }
        try? modelContext.save()
    }

    func evictAllDownloaded(itemsDirectory: URL) {
        enforceCacheLimit(maxBytes: 1, itemsDirectory: itemsDirectory)
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
