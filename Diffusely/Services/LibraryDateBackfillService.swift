import Foundation
import SwiftData

/// One-shot serial backfill: for every sidecar with no `publishedAt`,
/// re-fetch the image from Civitai, rewrite the JSON in place, and update
/// the corresponding index row. Failures are swallowed per-item so a
/// network hiccup on one image doesn't stop the rest of the queue.
///
/// Designed for view-driven on-demand triggering (mirrors how
/// `CollectionDetailView` runs its own date-backfill exactly once per view
/// instance). `@MainActor` so it can be observed by SwiftUI for the
/// "Backfilling publish dates… N remaining" indicator.
@MainActor
final class LibraryDateBackfillService: ObservableObject {

    /// Test seam so we don't need a live `CivitaiService` in unit tests.
    protocol FetchImageProvider: AnyObject {
        func fetchImage(imageId: Int) async throws -> CivitaiImage
    }

    @Published private(set) var remaining: Int = 0
    @Published private(set) var isRunning: Bool = false

    private let indexService: LibraryIndexService
    private let itemsDirectory: URL
    private let fetcher: FetchImageProvider

    init(
        indexService: LibraryIndexService,
        itemsDirectory: URL,
        fetcher: FetchImageProvider
    ) {
        self.indexService = indexService
        self.itemsDirectory = itemsDirectory
        self.fetcher = fetcher
    }

    /// Walk the sidecar directory once, backfill every item whose JSON has
    /// no `publishedAt`. Idempotent: re-running with everything already
    /// backfilled is a no-op.
    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let writer = LibraryFileWriter(itemsDirectory: itemsDirectory)
        let pending = enumeratePendingItems()
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

                try writer.rewriteMetadata(updated)
                let status = await indexService.currentDownloadStatus(itemID: metadata.itemID) ?? .downloaded
                await indexService.ingest(metadata: updated, downloadStatus: status)
            } catch {
                // Per-item failure: leave publishedAt nil and move on.
                continue
            }
        }
    }

    /// Read every sidecar JSON in the directory and return those missing
    /// `publishedAt`. This is the source of truth; the index is just a cache.
    private func enumeratePendingItems() -> [LibraryItemMetadata] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil)) ?? []
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
    }
}
