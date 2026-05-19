import Foundation
import SwiftData
import Combine

/// Syncs the user's *list* of collections into the local cache, mirroring
/// `CollectionSyncService` (which syncs a collection's *contents*). Cached
/// rows render instantly; this refreshes them in the background with the same
/// transient-error retry/backoff policy.
@MainActor
class CollectionListSyncService: ObservableObject {
    typealias SyncProgress = CollectionSyncService.SyncProgress
    typealias RetryState = CollectionSyncService.RetryState

    @Published var progress: SyncProgress?

    private let civitaiService: CivitaiService
    private let persistenceService: CollectionPersistenceService
    private var syncTask: Task<Void, Never>?

    init(civitaiService: CivitaiService, persistenceService: CollectionPersistenceService) {
        self.civitaiService = civitaiService
        self.persistenceService = persistenceService
    }

    /// Starts a background list sync. Returns immediately; cancels any in-flight sync.
    func startSync() {
        syncTask?.cancel()
        syncTask = Task { await performSync() }
    }

    /// True while a sync task is alive and not finished. A non-nil
    /// `retryState` still counts as syncing (the task is sleeping between
    /// retries), matching `CollectionSyncService.isSyncing`.
    var isSyncing: Bool {
        guard syncTask != nil, let progress else { return false }
        return !progress.isComplete && progress.lastError == nil
    }

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func performSync() async {
        persistenceService.markListSyncStarted()
        let generation = persistenceService.beginFreshListSyncPass()

        progress = SyncProgress(
            itemsFetched: persistenceService.getUserListCollections().count,
            isComplete: false,
            lastError: nil,
            retryState: nil
        )

        defer { syncTask = nil }

        do {
            let collections = try await fetchWithRetry {
                try await self.civitaiService.getAllUserCollections()
            }

            try Task.checkCancellation()

            for (index, collection) in collections.enumerated() {
                persistenceService.upsertUserListCollection(
                    from: collection, order: index, generation: generation
                )
            }
            progress?.itemsFetched = persistenceService.getUserListCollections().count

            persistenceService.markListSyncCompleted(generation: generation)
            progress?.isComplete = true

        } catch {
            if !(error is CancellationError) {
                progress?.lastError = error
            }
            // Clear the persisted "list syncing" flag (no sweep) so a reopen
            // retries instead of trusting a half-finished pass.
            persistenceService.markListSyncInterrupted()
        }
    }

    /// Runs `fetch`, retrying on transient errors with backoff. Sets
    /// `retryState` while paused; clears it on success. Fatal errors and
    /// cancellation propagate. Mirrors `CollectionSyncService.fetchPageWithRetry`.
    private func fetchWithRetry<T>(_ fetch: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                let result = try await fetch()
                if progress?.retryState != nil {
                    progress?.retryState = nil
                }
                return result
            } catch {
                try Task.checkCancellation()
                switch classifySyncError(error) {
                case .cancellation:
                    throw error
                case .fatal:
                    throw error
                case .transient:
                    attempt += 1
                    let delay = syncRetryDelay(forAttempt: attempt)
                    progress?.retryState = RetryState(
                        attempt: attempt,
                        nextAttemptAt: Date().addingTimeInterval(delay)
                    )
                    try await Task.sleep(for: .seconds(delay))
                    // loop: retry the same fetch
                }
            }
        }
    }
}
