import Foundation
import SwiftData

/// Bridges the live `CivitaiService` to `LibraryDateBackfillService.FetchImageProvider`.
/// Lives here (not in a view) so multiple call sites — the bulk backfill in
/// `LibraryView` and the per-item catchup from `LibraryDetailView` — share
/// one adapter type. `@MainActor` because `CivitaiService` is main-actor
/// isolated and the backfill service is too.
@MainActor
final class CivitaiServiceFetchImageAdapter: LibraryDateBackfillService.FetchImageProvider {
    private let service = CivitaiService()
    func fetchImage(imageId: Int) async throws -> CivitaiImage {
        try await service.fetchImage(imageId: imageId)
    }
}

/// Sidecar-store seam for `LibraryDateBackfillService`. Implementations are
/// responsible for performing the actual file I/O off the main thread; the
/// service awaits these calls from `@MainActor` so it can drive `@Published`
/// state, but the disk work must not block the UI.
protocol LibraryBackfillSidecarStore: Sendable {
    /// Returns the metadata for every sidecar JSON that is missing `publishedAt`.
    func pendingItems() async throws -> [LibraryItemMetadata]
    /// Atomically rewrites the sidecar JSON for an already-committed item.
    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws
}

/// Default file-backed implementation. Both methods hop to a detached task so
/// the directory walk + JSON decode (pending enumeration) and the
/// `NSFileCoordinator`-bound atomic write (rewrite) never run on the caller's
/// actor. With iCloud-backed `itemsDirectory`s the coordinator can block for
/// hundreds of ms while iCloud arbitrates access — keeping that off `@MainActor`
/// is what fixes the per-item Library hitch.
struct FileLibraryBackfillSidecarStore: LibraryBackfillSidecarStore {
    let itemsDirectory: URL

    func pendingItems() async throws -> [LibraryItemMetadata] {
        let directory = itemsDirectory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var pending: [LibraryItemMetadata] = []
            for url in urls where url.pathExtension == "json" {
                guard
                    let data = try? Data(contentsOf: url),
                    let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data),
                    metadata.publishedAt == nil,
                    // v4: items previously attempted (API confirmed null) are
                    // skipped by background scans. The detail-view catchup is
                    // the path that retries them, scoped to one item at a time.
                    metadata.publishedAtBackfillAttemptedAt == nil
                else { continue }
                pending.append(metadata)
            }
            return pending
        }.value
    }

    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws {
        let directory = itemsDirectory
        try await Task.detached(priority: .utility) {
            let writer = LibraryFileWriter(itemsDirectory: directory)
            try writer.rewriteMetadata(metadata)
        }.value
    }
}

/// One-shot serial backfill: for every sidecar with no `publishedAt`,
/// re-fetch the image from Civitai, rewrite the JSON in place, and update
/// the corresponding index row. Failures are swallowed per-item so a
/// network hiccup on one image doesn't stop the rest of the queue.
///
/// Designed for view-driven on-demand triggering (mirrors how
/// `CollectionDetailView` runs its own date-backfill exactly once per view
/// instance). `@MainActor` so it can be observed by SwiftUI for the
/// "Backfilling publish dates… N remaining" indicator — but file I/O is
/// delegated to a `LibraryBackfillSidecarStore` so the heavy work stays off
/// the main thread.
@MainActor
final class LibraryDateBackfillService: ObservableObject {

    /// Test seam so we don't need a live `CivitaiService` in unit tests.
    protocol FetchImageProvider: AnyObject {
        func fetchImage(imageId: Int) async throws -> CivitaiImage
    }

    @Published private(set) var remaining: Int = 0
    @Published private(set) var isRunning: Bool = false

    private let indexService: LibraryIndexService
    private let sidecarStore: LibraryBackfillSidecarStore
    private let fetcher: FetchImageProvider

    init(
        indexService: LibraryIndexService,
        sidecarStore: LibraryBackfillSidecarStore,
        fetcher: FetchImageProvider
    ) {
        self.indexService = indexService
        self.sidecarStore = sidecarStore
        self.fetcher = fetcher
    }

    /// Convenience initializer that constructs the default file-backed
    /// sidecar store. Keeps existing call sites (Views, older tests) working.
    convenience init(
        indexService: LibraryIndexService,
        itemsDirectory: URL,
        fetcher: FetchImageProvider
    ) {
        self.init(
            indexService: indexService,
            sidecarStore: FileLibraryBackfillSidecarStore(itemsDirectory: itemsDirectory),
            fetcher: fetcher
        )
    }

    /// Walk the sidecar directory once, backfill every item whose JSON has
    /// no `publishedAt`. Idempotent: re-running with everything already
    /// backfilled is a no-op.
    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let pending = (try? await sidecarStore.pendingItems()) ?? []
        remaining = pending.count

        for metadata in pending {
            if Task.isCancelled { return }
            defer { remaining = max(0, remaining - 1) }

            let image: CivitaiImage
            do {
                image = try await fetcher.fetchImage(imageId: metadata.itemID)
            } catch {
                // Transient failure (network down, server error): leave the
                // marker untouched so the next session retries this item.
                continue
            }

            let updated: LibraryItemMetadata
            if let publishedAt = image.publishedAtDate {
                updated = Self.merged(
                    base: metadata,
                    publishedAt: publishedAt,
                    stats: image.stats ?? metadata.stats,
                    attemptedAt: nil
                )
            } else {
                // API confirmed null: stamp the marker so background scans
                // stop re-asking. User-driven catchup (detail view) still
                // retries this item on demand.
                updated = Self.merged(
                    base: metadata,
                    publishedAt: nil,
                    stats: metadata.stats,
                    attemptedAt: Date()
                )
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

    /// User-initiated single-item catchup. Called when the user opens a
    /// library item whose `publishedAt` is still nil — including items the
    /// background scan has already given up on (marker set). One API call,
    /// best-effort: returns the rewritten metadata on success, nil if there
    /// was nothing to do or the fetch failed.
    func attemptCatchup(for metadata: LibraryItemMetadata) async -> LibraryItemMetadata? {
        guard metadata.publishedAt == nil else { return nil }

        let image: CivitaiImage
        do {
            image = try await fetcher.fetchImage(imageId: metadata.itemID)
        } catch {
            // Transient: leave the existing marker untouched so this attempt
            // doesn't reset the backoff. Try again next time the user opens.
            return nil
        }

        let updated: LibraryItemMetadata
        if let publishedAt = image.publishedAtDate {
            updated = Self.merged(
                base: metadata,
                publishedAt: publishedAt,
                stats: image.stats ?? metadata.stats,
                attemptedAt: nil
            )
        } else {
            // Still null. Refresh the marker so that, if the user opens the
            // item repeatedly, we still only call the API once per open.
            updated = Self.merged(
                base: metadata,
                publishedAt: nil,
                stats: metadata.stats,
                attemptedAt: Date()
            )
        }

        do {
            try await sidecarStore.rewriteMetadata(updated)
        } catch {
            return nil
        }
        let status = await indexService.currentDownloadStatus(itemID: metadata.itemID) ?? .downloaded
        await indexService.ingest(metadata: updated, downloadStatus: status)
        return updated
    }

    /// Build a v4 sidecar from an existing one, swapping in fresh
    /// `publishedAt`, `stats`, and the `publishedAtBackfillAttemptedAt`
    /// marker. Everything else is preserved verbatim.
    private static func merged(
        base: LibraryItemMetadata,
        publishedAt: Date?,
        stats: ImageStats?,
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
            stats: stats,
            generationData: base.generationData,
            publishedAt: publishedAt,
            publishedAtBackfillAttemptedAt: attemptedAt,
            savedAt: base.savedAt,
            savedByAppVersion: base.savedByAppVersion
        )
    }
}
