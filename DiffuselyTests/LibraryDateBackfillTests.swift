import Testing
import Foundation
import SwiftData
@testable import Diffusely

// Local helper duplicates the LibrarySortTests `makeMeta` to keep this file
// self-contained.
private func makeMeta(
    itemID: Int,
    mediaType: LibraryMediaType = .image,
    publishedAt: Date? = nil
) -> LibraryItemMetadata {
    LibraryItemMetadata(
        schemaVersion: LibraryItemMetadata.currentSchemaVersion,
        itemID: itemID,
        sourcePostID: nil,
        sourcePostTitle: nil,
        canonicalPostURL: nil,
        canonicalPageURL: "https://civitai.com/images/\(itemID)",
        sourceDomain: "civitai.com",
        originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).\(mediaType.fileExtension)",
        mediaType: mediaType,
        mediaFileName: "\(itemID).\(mediaType.fileExtension)",
        fileByteSize: 1,
        contentSHA256: "x",
        width: 1, height: 1, nsfwLevel: 1,
        author: LibraryAuthor(id: 1, username: "alice", avatarURL: nil),
        stats: nil,
        generationData: nil,
        publishedAt: publishedAt,
        savedAt: Date(),
        savedByAppVersion: "t"
    )
}

private final class StubFetchImageProvider: LibraryDateBackfillService.FetchImageProvider {
    var responses: [Int: CivitaiImage] = [:]
    var requestedIDs: [Int] = []
    var errorForID: Set<Int> = []
    func fetchImage(imageId: Int) async throws -> CivitaiImage {
        requestedIDs.append(imageId)
        if errorForID.contains(imageId) {
            throw URLError(.notConnectedToInternet)
        }
        guard let img = responses[imageId] else { throw URLError(.cannotFindHost) }
        return img
    }
}

/// Test seam for the new sidecar-store dependency. Captures every call and
/// records whether it ran on the main thread so we can prove the production
/// code no longer does file I/O on @MainActor.
private final class RecordingSidecarStore: LibraryBackfillSidecarStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [LibraryItemMetadata]
    private var _pendingItemsCallCount = 0
    private var _pendingItemsRanOnMainThread: [Bool] = []
    private var _rewrittenItems: [LibraryItemMetadata] = []
    private var _rewriteRanOnMainThread: [Bool] = []

    init(pending: [LibraryItemMetadata]) { self._pending = pending }

    var pendingItemsCallCount: Int { lock.withLock { _pendingItemsCallCount } }
    var pendingItemsRanOnMainThread: [Bool] { lock.withLock { _pendingItemsRanOnMainThread } }
    var rewrittenItems: [LibraryItemMetadata] { lock.withLock { _rewrittenItems } }
    var rewriteRanOnMainThread: [Bool] { lock.withLock { _rewriteRanOnMainThread } }

    func pendingItems() async throws -> [LibraryItemMetadata] {
        let onMain = Thread.isMainThread
        return lock.withLock {
            _pendingItemsCallCount += 1
            _pendingItemsRanOnMainThread.append(onMain)
            return _pending
        }
    }

    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws {
        let onMain = Thread.isMainThread
        lock.withLock {
            _rewriteRanOnMainThread.append(onMain)
            _rewrittenItems.append(metadata)
        }
    }
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func civitaiImage(id: Int, publishedAtISO: String?) -> CivitaiImage {
    CivitaiImage(
        id: id,
        url: "uuid-\(id)",
        width: 1, height: 1, nsfwLevel: 1,
        type: "image",
        postId: nil,
        user: nil,
        stats: nil,
        thumbnailUrl: nil,
        publishedAt: publishedAtISO
    )
}

@Suite struct LibraryDateBackfillTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @Test func backfillRewritesSidecarsAndUpdatesIndexRows() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two items, both missing publishedAt, plus media files.
        for id in [10, 11] {
            let m = makeMeta(itemID: id, publishedAt: nil)
            try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("\(id).json"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        stub.responses[10] = civitaiImage(id: 10, publishedAtISO: "2024-03-22T10:52:00.000Z")
        stub.responses[11] = civitaiImage(id: 11, publishedAtISO: "2024-03-23T11:00:00.000Z")

        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        #expect(Set(stub.requestedIDs) == [10, 11])

        // Sidecars rewritten with publishedAt.
        for id in [10, 11] {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(id).json"))
            let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            #expect(decoded.publishedAt != nil)
        }

        // Index rows updated.
        let rows = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(rows.allSatisfy { $0.publishedAt != nil })
    }

    @Test func backfillSkipsItemsThatAlreadyHavePublishedAt() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let already = Date(timeIntervalSince1970: 1_700_000_000)
        let m = makeMeta(itemID: 20, publishedAt: already)
        try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("20.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("20.jpeg"))

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        #expect(stub.requestedIDs.isEmpty)
    }

    @Test func backfillContinuesPastTransientFailure() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for id in [30, 31] {
            let m = makeMeta(itemID: id, publishedAt: nil)
            try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("\(id).json"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        stub.errorForID = [30]
        stub.responses[31] = civitaiImage(id: 31, publishedAtISO: "2024-03-23T11:00:00.000Z")

        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        // Both attempted; only 31 succeeded.
        #expect(Set(stub.requestedIDs) == [30, 31])

        let data31 = try Data(contentsOf: dir.appendingPathComponent("31.json"))
        let decoded31 = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data31)
        #expect(decoded31.publishedAt != nil)

        let data30 = try Data(contentsOf: dir.appendingPathComponent("30.json"))
        let decoded30 = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data30)
        #expect(decoded30.publishedAt == nil)
    }

    @Test func backfillPreservesEvictedDownloadStatus() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Sidecar present but NO media file → reconcile classifies as .evicted.
        let m = makeMeta(itemID: 50, publishedAt: nil)
        try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("50.json"))
        // (Intentionally no 50.jpeg on disk.)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        // Sanity check: row exists and is .evicted.
        let before = try await MainActor.run { () -> PersistedLibraryItem? in
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>()).first
        }
        #expect(before?.downloadStatus == .evicted)

        let stub = StubFetchImageProvider()
        stub.responses[50] = civitaiImage(id: 50, publishedAtISO: "2024-03-22T10:52:00.000Z")

        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        let after = try await MainActor.run { () -> PersistedLibraryItem? in
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>()).first
        }
        #expect(after?.publishedAt != nil)
        // Critical: backfill did not clobber the .evicted status.
        #expect(after?.downloadStatus == .evicted)
    }

    @Test func backfillUsesInjectedSidecarStoreAndRunsItsIOOffMainThread() async throws {
        let m = makeMeta(itemID: 70, publishedAt: nil)
        let store = RecordingSidecarStore(pending: [m])

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        // Seed the index so the per-item ingest finds an existing row.
        await index.ingest(metadata: m, downloadStatus: .downloaded)

        let stub = StubFetchImageProvider()
        stub.responses[70] = civitaiImage(id: 70, publishedAtISO: "2024-03-22T10:52:00.000Z")

        let svc = await LibraryDateBackfillService(
            indexService: index,
            sidecarStore: store,
            fetcher: stub
        )
        await svc.runOnce()

        // The service delegated enumeration + rewrite to the store.
        #expect(store.pendingItemsCallCount == 1)
        #expect(store.rewrittenItems.count == 1)
        #expect(store.rewrittenItems.first?.itemID == 70)
        #expect(store.rewrittenItems.first?.publishedAt != nil)

        // Every store callback ran off the main thread — this is what cures the
        // UI choppiness reported when the user enters the Library tab.
        #expect(store.pendingItemsRanOnMainThread.allSatisfy { $0 == false })
        #expect(store.rewriteRanOnMainThread.allSatisfy { $0 == false })
    }

    @Test func backfillLeavesSidecarUntouchedWhenAPIReturnsNoPublishedAt() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let m = makeMeta(itemID: 60, publishedAt: nil)
        try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("60.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("60.jpeg"))

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        // API returns the image but with no publishedAt.
        stub.responses[60] = civitaiImage(id: 60, publishedAtISO: nil)

        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        // Stub WAS called…
        #expect(stub.requestedIDs == [60])
        // …but the sidecar wasn't rewritten because there was no publishedAt to add.
        let data = try Data(contentsOf: dir.appendingPathComponent("60.json"))
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.publishedAt == nil)
    }
}
