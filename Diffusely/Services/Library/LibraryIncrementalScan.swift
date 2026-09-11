import Foundation
import CryptoKit

/// Queue-confined, nonrecursive enumeration. Never buffers the whole directory.
final class LibraryScanCursor: @unchecked Sendable {
    private var enumerator: FileManager.DirectoryEnumerator?
    private var failed = false
    private(set) var checksUbiquity = true

    init(directory: URL) {
        let values = try? directory.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
        checksUbiquity = LibraryIndexService.shouldCheckUbiquity(
            directoryIsUbiquitous: values?.isUbiquitousItem, volumeIsLocal: values?.volumeIsLocal)
        enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: LibraryIndexService.scanPrefetchKeys(checksUbiquity: checksUbiquity),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { [weak self] _, _ in self?.failed = true; return false })
        if enumerator == nil { failed = true }
    }

    func next(limit: Int) -> (urls: [URL], finished: Bool)? {
        guard !failed else { return nil }
        var urls: [URL] = []
        while urls.count < max(1, limit) {
            guard let url = enumerator?.nextObject() as? URL else {
                return failed ? nil : (urls, true)
            }
            urls.append(url)
        }
        return failed ? nil : (urls, false)
    }
}

/// Only completed database commits are checkpointed. No directory offsets are
/// persisted: enumeration order can change between launches. Resume rechecks
/// each saved fingerprint, and deletion still requires a fresh complete walk.
struct LibraryScanCheckpoint: Codable {
    struct Fingerprint: Codable, Equatable {
        var modifiedAt: Date
        var size: Int
        var itemID: Int
    }
    var version = 1
    var root: String
    var completed: [String: Fingerprint] = [:]

    static func url(directory: URL) -> URL {
        let key = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diffusely/ScanCheckpoints", isDirectory: true)
            .appendingPathComponent(key + ".json")
    }

    static func existing(at url: URL?, root: String) -> Self? {
        guard let url, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.root == root else { return nil }
        return value
    }

    static func load(at url: URL?, root: String) -> Self {
        existing(at: url, root: root) ?? Self(root: root)
    }

    func save(at url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

extension LibraryIndexService {
    typealias Fingerprints = [String: (modifiedAt: Date?, size: Int, itemID: Int, mediaFileName: String)]

    nonisolated static func scanIO<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            scanQueue.async { continuation.resume(returning: work()) }
        }
    }

    static func emptyScan() -> ScanResult {
        ([], [], [], [], 0, 0, [], ScanMetrics())
    }

    func reconcileInBatches(
        store: LibraryFileStore, knownItems: Set<Int>, knownAlbums: Set<UUID>,
        fingerprints: Fingerprints, isPlaceholder: PlaceholderCheck?,
        epoch: Int, startedAtGeneration: Int,
        generationProbe: @Sendable @escaping () async -> Int,
        rebuilding: Bool, progress: (@Sendable (Int) async -> Void)?,
        checkpointURL: URL?, batchSize: Int = 256,
        finalizeCheck: @Sendable @escaping () async -> Bool = { true }
    ) async -> ReconcileOutcome {
        let root = store.itemsDirectory.standardizedFileURL.path + (store.isEncrypted ? "#encrypted" : "#plain")
        // Tests have in-memory databases; they only persist a checkpoint when
        // explicitly given a temporary URL by the test.
        let checkpointURL = rebuilding ? (checkpointURL ?? (
            modelContainer.configurations.allSatisfy(\.isStoredInMemoryOnly) ? nil :
                LibraryScanCheckpoint.url(directory: store.itemsDirectory))) : nil
        var checkpoint = await Self.scanIO { LibraryScanCheckpoint.load(at: checkpointURL, root: root) }
        var trusted = fingerprints
        if rebuilding {
            let saved = indexedFingerprints()
            trusted = saved.filter { name, value in
                guard let date = value.modifiedAt else { return false }
                return checkpoint.completed[name] == .init(modifiedAt: date, size: value.size, itemID: value.itemID)
            }
        }
        let cursor = await Self.scanIO { LibraryScanCursor(directory: store.itemsDirectory) }
        var complete = Self.emptyScan()
        var changed = false
        var processed = 0
        var sidecarsRead = 0
        var listingSeconds = 0.0
        while !Task.isCancelled {
            let start = Date()
            guard let page = await Self.scanIO({ cursor.next(limit: batchSize) }) else {
                print("[LibraryIndex] incomplete enumeration; keeping existing rows")
                return ReconcileOutcome(albumStateChanged: changed)
            }
            listingSeconds += Date().timeIntervalSince(start)
            let batchFingerprints = trusted
            guard let scan = await Self.scanIO({
                Self.scanContainer(store: store, indexedItemIDs: knownItems,
                    indexedAlbumIDs: knownAlbums, isPlaceholder: isPlaceholder,
                    fingerprints: batchFingerprints, listedContents: page.urls,
                    storageChecksUbiquity: cursor.checksUbiquity)
            }) else { return ReconcileOutcome(albumStateChanged: changed) }
            guard await generationProbe() == startedAtGeneration,
                  currentMutationEpoch() == epoch, !Task.isCancelled else {
                return ReconcileOutcome(albumStateChanged: changed)
            }
            // A batch may upsert; it may never infer deletion from absence.
            let batchChanged: Bool
            let committedWholeBatch: Bool
            if let result = reconcileBatched(scan, pruneMissing: false) {
                batchChanged = result
                committedWholeBatch = true
            } else {
                modelContext.rollback()
                // Retain the existing poison-row recovery behavior. A partial
                // recovery is deliberately not checkpointed as a whole batch.
                batchChanged = reconcilePerItem(scan, pruneMissing: false)
                committedWholeBatch = false
            }
            changed = changed || batchChanged
            complete.seenIDs.formUnion(scan.seenIDs)
            complete.seenAlbumIDs.formUnion(scan.seenAlbumIDs)
            complete.pendingItems += scan.pendingItems
            complete.pendingAlbums += scan.pendingAlbums
            sidecarsRead += scan.metrics.sidecarsRead
            processed += scan.items.count + scan.statusUpdates.count
            if rebuilding && committedWholeBatch {
                for item in scan.items {
                    if let date = item.sidecarModifiedAt {
                        checkpoint.completed[item.sidecarFileName] = .init(
                            modifiedAt: date, size: item.sidecarByteSize, itemID: item.metadata.itemID)
                    }
                }
                let savedCheckpoint = checkpoint
                await Self.scanIO {
                    do { try savedCheckpoint.save(at: checkpointURL) }
                    catch { print("[LibraryIndex] checkpoint could not be saved: \(error)") }
                }
            }
            await progress?(processed)
            if page.finished {
                // A writer that changed the journal during enumeration makes
                // absence ambiguous; keep published rows but defer pruning.
                guard await finalizeCheck() else { return ReconcileOutcome(albumStateChanged: changed) }
                // Progress callbacks can suspend or mutate the root/index.
                guard await generationProbe() == startedAtGeneration,
                      currentMutationEpoch() == epoch, !Task.isCancelled else {
                    return ReconcileOutcome(albumStateChanged: changed)
                }
                guard let finalChanged = reconcileBatched(complete) else {
                    modelContext.rollback()
                    return ReconcileOutcome(albumStateChanged: changed)
                }
                if let checkpointURL {
                    await Self.scanIO { try? FileManager.default.removeItem(at: checkpointURL) }
                }
                print("[LibraryIndex] completed \(processed) items in batches (\(sidecarsRead) sidecars read); listing \(String(format: "%.2f", listingSeconds))s; cloud checks \(cursor.checksUbiquity ? "on" : "off")")
                return ReconcileOutcome(albumStateChanged: changed || finalChanged,
                    pendingItems: complete.pendingItems, pendingAlbums: complete.pendingAlbums, sidecarsRead: sidecarsRead)
            }
        }
        return ReconcileOutcome(albumStateChanged: changed)
    }
}
