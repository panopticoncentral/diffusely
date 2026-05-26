import Foundation
import SwiftData

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
                    metadata.publishedAt == nil
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

            do {
                let image = try await fetcher.fetchImage(imageId: metadata.itemID)
                guard let publishedAt = image.publishedAtDate else { continue }

                let updated = LibraryItemMetadata(
                    schemaVersion: LibraryItemMetadata.currentSchemaVersion,
                    itemID: metadata.itemID,
                    sourcePostID: metadata.sourcePostID,
                    sourcePostTitle: metadata.sourcePostTitle,
                    canonicalPostURL: metadata.canonicalPostURL,
                    canonicalPageURL: metadata.canonicalPageURL,
                    sourceDomain: metadata.sourceDomain,
                    originalCDNURL: metadata.originalCDNURL,
                    mediaType: metadata.mediaType,
                    mediaFileName: metadata.mediaFileName,
                    fileByteSize: metadata.fileByteSize,
                    contentSHA256: metadata.contentSHA256,
                    width: metadata.width,
                    height: metadata.height,
                    nsfwLevel: metadata.nsfwLevel,
                    author: metadata.author,
                    stats: image.stats ?? metadata.stats,
                    generationData: metadata.generationData,
                    publishedAt: publishedAt,
                    savedAt: metadata.savedAt,
                    savedByAppVersion: metadata.savedByAppVersion
                )

                try await sidecarStore.rewriteMetadata(updated)
                let status = await indexService.currentDownloadStatus(itemID: metadata.itemID) ?? .downloaded
                await indexService.ingest(metadata: updated, downloadStatus: status)
            } catch {
                // Per-item failure: leave publishedAt nil and move on.
                continue
            }
        }
    }
}
