import Foundation
import SwiftData
import Combine

@MainActor
class CollectionSyncService: ObservableObject {
    struct SyncProgress {
        var itemsFetched: Int
        var isComplete: Bool
        var lastError: Error?
    }

    @Published var syncProgress: [Int: SyncProgress] = [:]  // collectionId -> progress

    private let civitaiService: CivitaiService
    private let persistenceService: CollectionPersistenceService
    private var syncTasks: [Int: Task<Void, Never>] = [:]

    init(civitaiService: CivitaiService, persistenceService: CollectionPersistenceService) {
        self.civitaiService = civitaiService
        self.persistenceService = persistenceService
    }

    /// Starts syncing a collection in the background
    /// Returns immediately, sync continues progressively
    func startSync(for collection: CivitaiCollection) {
        // Cancel existing sync for this collection
        syncTasks[collection.id]?.cancel()

        let task = Task {
            await performSync(for: collection)
        }
        syncTasks[collection.id] = task
    }

    /// Check if a sync is currently running for a collection
    func isSyncing(collectionId: Int) -> Bool {
        guard let progress = syncProgress[collectionId] else { return false }
        return !progress.isComplete && progress.lastError == nil
    }

    private func performSync(for collection: CivitaiCollection) async {
        let persisted = persistenceService.getOrCreateCollection(from: collection)
        persistenceService.markSyncStarted(for: collection.id)

        // Initialize progress
        let initialCount = persisted.itemCount
        syncProgress[collection.id] = SyncProgress(
            itemsFetched: initialCount,
            isComplete: false,
            lastError: nil
        )

        do {
            if collection.type == "Image" {
                try await syncImages(for: collection, persisted: persisted)
            } else if collection.type == "Post" {
                try await syncPosts(for: collection, persisted: persisted)
            }

            persistenceService.markSyncCompleted(for: collection.id)
            syncProgress[collection.id]?.isComplete = true

        } catch {
            if !(error is CancellationError) {
                syncProgress[collection.id]?.lastError = error
            }
        }
    }

    private func syncImages(for collection: CivitaiCollection, persisted: PersistedCollection) async throws {
        // Resume from stored cursor if available
        var cursor: String? = persisted.syncCursor
        var pageCount = 0

        print("[Sync] Starting image sync for collection \(collection.id), existing: \(persisted.images.count), cursor: \(cursor ?? "nil")")

        while !Task.isCancelled {
            pageCount += 1
            print("[Sync] Fetching page \(pageCount) with cursor: \(cursor ?? "nil")")

            let (images, nextCursor) = try await civitaiService.fetchImagesPage(
                collectionId: collection.id,
                cursor: cursor,
                limit: 100
            )

            print("[Sync] Page \(pageCount): fetched \(images.count) images, nextCursor: \(nextCursor ?? "nil")")

            // Check cancellation before persisting
            try Task.checkCancellation()

            // Persist the fetched images (duplicates are skipped)
            persistenceService.addImages(images, to: persisted)

            // Use actual persisted count (not cumulative fetch count) to handle duplicates correctly
            syncProgress[collection.id]?.itemsFetched = persisted.images.count

            // Save cursor for resume capability
            persistenceService.updateSyncCursor(for: collection.id, cursor: nextCursor)

            // Only stop if there's no next cursor (meaning we've reached the end)
            if nextCursor == nil {
                print("[Sync] No more pages - sync complete. Total items: \(persisted.images.count)")
                break
            }

            cursor = nextCursor

            // Small delay to avoid hammering the API
            try await Task.sleep(for: .milliseconds(100))
        }

        print("[Sync] Image sync finished for collection \(collection.id). Pages: \(pageCount), Total items: \(persisted.images.count)")
    }

    private func syncPosts(for collection: CivitaiCollection, persisted: PersistedCollection) async throws {
        // Resume from stored cursor if available
        var cursor: String? = persisted.syncCursor
        var pageCount = 0

        print("[Sync] Starting post sync for collection \(collection.id), existing: \(persisted.posts.count), cursor: \(cursor ?? "nil")")

        while !Task.isCancelled {
            pageCount += 1
            print("[Sync] Fetching page \(pageCount) with cursor: \(cursor ?? "nil")")

            let (posts, nextCursor) = try await civitaiService.fetchPostsPage(
                collectionId: collection.id,
                cursor: cursor,
                limit: 100
            )

            print("[Sync] Page \(pageCount): fetched \(posts.count) posts, nextCursor: \(nextCursor ?? "nil")")

            // Check cancellation before persisting
            try Task.checkCancellation()

            // Persist the fetched posts (duplicates are skipped)
            persistenceService.addPosts(posts, to: persisted)

            // Use actual persisted count (not cumulative fetch count) to handle duplicates correctly
            syncProgress[collection.id]?.itemsFetched = persisted.posts.count

            // Save cursor for resume capability
            persistenceService.updateSyncCursor(for: collection.id, cursor: nextCursor)

            // Only stop if there's no next cursor (meaning we've reached the end)
            if nextCursor == nil {
                print("[Sync] No more pages - sync complete. Total items: \(persisted.posts.count)")
                break
            }

            cursor = nextCursor

            // Small delay to avoid hammering the API
            try await Task.sleep(for: .milliseconds(100))
        }

        print("[Sync] Post sync finished for collection \(collection.id). Pages: \(pageCount), Total items: \(persisted.posts.count)")
    }

    func cancelSync(for collectionId: Int) {
        syncTasks[collectionId]?.cancel()
        syncTasks.removeValue(forKey: collectionId)
    }

    func cancelAllSyncs() {
        for task in syncTasks.values {
            task.cancel()
        }
        syncTasks.removeAll()
    }
}
