import Foundation

/// Sidecar-store seam for `LibraryCheckpointBackfillService`. Deliberately a
/// separate protocol from `LibraryBackfillSidecarStore` (dates) because the
/// pending query differs; `FileLibraryBackfillSidecarStore` conforms to both
/// so there is still exactly one vault-aware container walk implementation.
protocol LibraryCheckpointBackfillSidecarStore: Sendable {
    /// Metadata for every sidecar with NO generation data that hasn't already
    /// been attempted.
    func itemsMissingGenerationData() async throws -> [LibraryItemMetadata]
    /// Atomically rewrites the sidecar for an already-committed item.
    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws
}

extension FileLibraryBackfillSidecarStore: LibraryCheckpointBackfillSidecarStore {
    /// Same vault-aware, off-actor walk as `pendingItems()`, filtered for the
    /// generation-data backfill instead of the date one. A locked vault
    /// returns empty rather than scanning: a passthrough store built over an
    /// encrypted container would find zero readable sidecars and wrongly
    /// report nothing pending.
    func itemsMissingGenerationData() async throws -> [LibraryItemMetadata] {
        let directory = itemsDirectory
        let vault = await resolveVaultContext()
        guard vault.state != .locked else { return [] }
        let crypto = vault.crypto
        return await Task.detached(priority: .utility) {
            let store = LibraryFileStore(itemsDirectory: directory, crypto: crypto)
            var pending: [LibraryItemMetadata] = []
            for url in store.enumerateMetadataFiles() {
                guard
                    let id = store.itemID(forMetadataFile: url),
                    let data = store.readMetadata(itemID: id),
                    let metadata = try? LibraryItemMetadata.decoder()
                        .decode(LibraryItemMetadata.self, from: data),
                    PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: metadata)
                else { continue }
                pending.append(metadata)
            }
            return pending
        }.value
    }
}

/// One-shot serial backfill for items whose sidecar has no generation data:
/// re-fetch it from Civitai, rewrite the sidecar, and update the index row so
/// the item leaves the checkpoint sort's "Other"/"Videos" bucket.
///
/// Scope is deliberately narrow. Measured across a real 7,830-item library,
/// the 287 ungrouped items split three ways, and only ONE of them is
/// recoverable by asking Civitai again:
///
/// * no generation data at all (81) — 16 of 25 sampled have a checkpoint on
///   Civitai today. `fetchGenerationData` is called with `try?` at save time,
///   so a failure there is silent and permanent. This service exists for them.
/// * generation data with no `Checkpoint` resource (150), or with zero
///   resources (56) — 0 of 50 sampled gained a checkpoint. Civitai never
///   hash-matched a base model for these (ComfyUI and off-site uploads whose
///   base model is a raw file, not a Civitai model). Re-asking is ~206
///   requests for a near-certain nothing, so they are not eligible.
///
/// Mirrors `LibraryDateBackfillService`: `@MainActor` so SwiftUI can observe
/// `remaining` for the progress banner, with all file I/O delegated to a
/// `LibraryCheckpointBackfillSidecarStore` that keeps the heavy work off the
/// main thread. Failures are swallowed per item so one bad image doesn't stop
/// the queue.
@MainActor
final class LibraryCheckpointBackfillService: ObservableObject {

    /// Test seam so the suite needs no live `CivitaiService`.
    protocol FetchGenerationDataProvider: AnyObject {
        func fetchGenerationData(imageId: Int) async throws -> GenerationData
    }

    @Published private(set) var remaining: Int = 0
    @Published private(set) var isRunning: Bool = false

    private let indexService: LibraryIndexService
    private let sidecarStore: LibraryCheckpointBackfillSidecarStore
    private let fetcher: FetchGenerationDataProvider

    init(
        indexService: LibraryIndexService,
        sidecarStore: LibraryCheckpointBackfillSidecarStore,
        fetcher: FetchGenerationDataProvider
    ) {
        self.indexService = indexService
        self.sidecarStore = sidecarStore
        self.fetcher = fetcher
    }

    /// Convenience initializer that builds the default file-backed store,
    /// matching `LibraryDateBackfillService`'s.
    convenience init(
        indexService: LibraryIndexService,
        itemsDirectory: URL,
        fetcher: FetchGenerationDataProvider
    ) {
        self.init(
            indexService: indexService,
            sidecarStore: FileLibraryBackfillSidecarStore(itemsDirectory: itemsDirectory),
            fetcher: fetcher
        )
    }

    /// Walk the container once and re-fetch generation data for every eligible
    /// item. Idempotent: with everything filled or attempted, this is a no-op.
    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let pending = (try? await sidecarStore.itemsMissingGenerationData()) ?? []
        remaining = pending.count

        for metadata in pending {
            if Task.isCancelled { return }
            defer { remaining = max(0, remaining - 1) }

            let updated: LibraryItemMetadata
            do {
                let generationData = try await fetcher.fetchGenerationData(imageId: metadata.itemID)
                updated = Self.merged(base: metadata, generationData: generationData, attemptedAt: nil)
            } catch let error as DecodingError {
                // Civitai answered, but there is no generation data to decode
                // — `result.data.json` is null for deleted, unpublished, or
                // never-had-any images (8 of 25 sampled). Stamp the marker so
                // background scans stop re-asking forever.
                _ = error
                updated = Self.merged(base: metadata, generationData: nil, attemptedAt: Date())
            } catch {
                // Transient (timeout, offline, server error). Leave the marker
                // untouched so the next session retries — permanently marking
                // an item over one bad network moment is exactly the silent
                // data loss this service exists to repair.
                continue
            }

            do {
                try await sidecarStore.rewriteMetadata(updated)
            } catch {
                continue
            }
            let status = await indexService.currentDownloadStatus(itemID: metadata.itemID) ?? .downloaded
            await indexService.ingest(metadata: updated, downloadStatus: status)
        }
    }

    /// Build a current-schema sidecar from an existing one, swapping in the
    /// fetched generation data and the attempt marker. Everything else —
    /// `albumIDs` especially, whose silent default to [] once wiped album
    /// membership on every date-backfill rewrite — is preserved verbatim.
    private static func merged(
        base: LibraryItemMetadata,
        generationData: GenerationData?,
        attemptedAt: Date?
    ) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: base.itemID,
            sourcePostID: base.sourcePostID,
            sourcePostTitle: base.sourcePostTitle,
            canonicalPostURL: base.canonicalPostURL,
            canonicalPageURL: base.canonicalPageURL,
            sourceDomain: base.sourceDomain,
            originalCDNURL: base.originalCDNURL,
            mediaType: base.mediaType,
            mediaFileName: base.mediaFileName,
            fileByteSize: base.fileByteSize,
            contentSHA256: base.contentSHA256,
            width: base.width,
            height: base.height,
            nsfwLevel: base.nsfwLevel,
            author: base.author,
            stats: base.stats,
            generationData: generationData ?? base.generationData,
            publishedAt: base.publishedAt,
            publishedAtBackfillAttemptedAt: base.publishedAtBackfillAttemptedAt,
            generationDataBackfillAttemptedAt: attemptedAt,
            albumIDs: base.albumIDs,
            savedAt: base.savedAt,
            savedByAppVersion: base.savedByAppVersion
        )
    }
}

/// Bridges the live `CivitaiService` to the backfill's fetch seam, mirroring
/// `CivitaiServiceFetchImageAdapter` — `@MainActor` because `CivitaiService`
/// is main-actor isolated.
@MainActor
final class CivitaiServiceGenerationDataAdapter: LibraryCheckpointBackfillService.FetchGenerationDataProvider {
    private let service = CivitaiService()

    func fetchGenerationData(imageId: Int) async throws -> GenerationData {
        try await service.fetchGenerationData(imageId: imageId)
    }
}
