import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// Regression tests for the "items reappear in Not in any Album" bug: a
/// reconcile whose container scan was already in flight when the user added
/// items to an album would apply its pre-add snapshot over the just-written
/// index rows, resurrecting the items until the next reconcile healed them.
@Suite struct AlbumMembershipClobberTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func makeMeta(_ id: Int, albumIDs: [String] = []) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albumIDs, savedAt: Date(), savedByAppVersion: "t")
    }

    private func commitItem(_ id: Int, in dir: URL) throws {
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let tmp = dir.appendingPathComponent("dl-\(id).tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: makeMeta(id), mediaTempURL: tmp)
    }

    /// The race: a scan captured BEFORE an add-to-album must not be applied
    /// AFTER it — the membership written by the add has to survive.
    @Test func staleScanIsNotAppliedOverNewerMembership() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })

        for id in [1, 2] { try commitItem(id, in: dir) }
        await index.reconcile(itemsDirectory: dir)

        // An in-flight reconcile reads the container now (pre-add snapshot)…
        let epoch = await index.currentMutationEpoch()
        let staleScan = try #require(LibraryIndexService.scanContainer(itemsDirectory: dir))

        // …while the user adds the items to a new album.
        let album = await albumService.createAlbum(name: "A")
        await albumService.addItems([1, 2], toAlbum: album)

        // The racing reconcile finishes its scan and tries to apply it.
        let applied = await index.applyScan(staleScan, ifEpochMatches: epoch)
        #expect(applied == .rejectedStaleEpoch, "a scan older than a direct write must be rejected")

        // Membership and the album row must both survive.
        let ctx = ModelContext(container)
        let rows = try ctx.fetch(FetchDescriptor<PersistedLibraryItem>())
        for row in rows {
            #expect(row.albumIDs == [album.uuidString], "item \(row.itemID) lost its membership")
        }
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).count == 1)
    }

    /// Positive control: a scan with no interleaved writes applies normally.
    @Test func freshScanStillApplies() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })

        try commitItem(1, in: dir)
        await index.reconcile(itemsDirectory: dir)
        let album = await albumService.createAlbum(name: "A")
        await albumService.addItems([1], toAlbum: album)

        let epoch = await index.currentMutationEpoch()
        let freshScan = try #require(LibraryIndexService.scanContainer(itemsDirectory: dir))
        let applied = await index.applyScan(freshScan, ifEpochMatches: epoch)
        #expect(applied.wasApplied)

        let row = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == [album.uuidString])
    }

    /// End-to-end: reconcile() itself must leave post-scan writes intact even
    /// when one lands mid-reconcile (epoch moves -> rescan picks up the truth).
    @Test func reconcileAfterWritesKeepsMembership() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })

        for id in [1, 2, 3] { try commitItem(id, in: dir) }
        await index.reconcile(itemsDirectory: dir)

        let album = await albumService.createAlbum(name: "A")
        await albumService.addItems([1, 2], toAlbum: album)
        await index.reconcile(itemsDirectory: dir)

        let ctx = ModelContext(container)
        let byID = Dictionary(
            try ctx.fetch(FetchDescriptor<PersistedLibraryItem>()).map { ($0.itemID, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        #expect(byID[1]?.albumIDs == [album.uuidString])
        #expect(byID[2]?.albumIDs == [album.uuidString])
        #expect(byID[3]?.albumIDs == [])
    }
}

/// Regression test for the sibling data-loss bug: the publish-date backfill
/// rewrites sidecars via `merged(base:...)`, which must preserve `albumIDs`
/// (it silently defaulted them to [] — wiping membership from the source of
/// truth for any album member the backfill touched).
@Suite struct BackfillPreservesAlbumMembershipTests {
    private final class StubFetcher: LibraryDateBackfillService.FetchImageProvider {
        func fetchImage(imageId: Int) async throws -> CivitaiImage {
            CivitaiImage(
                id: imageId, url: "uuid-\(imageId)", width: 1, height: 1, nsfwLevel: 1,
                type: "image", postId: nil, user: nil, stats: nil, thumbnailUrl: nil,
                publishedAt: "2024-03-22T10:52:00.000Z"
            )
        }
    }

    @Test func backfillRewritePreservesAlbumMembership() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let albumID = UUID().uuidString
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: 10, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "10.jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [albumID], savedAt: Date(), savedByAppVersion: "t")
        try LibraryItemMetadata.encoder().encode(meta).write(to: dir.appendingPathComponent("10.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("10.jpeg"))

        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let svc = await LibraryDateBackfillService(
            indexService: index, itemsDirectory: dir, fetcher: StubFetcher()
        )
        await svc.runOnce()

        // Sidecar (the source of truth) must keep its membership.
        let rewritten = try #require(LibraryFileWriter(itemsDirectory: dir).readMetadata(itemID: 10))
        #expect(rewritten.publishedAt != nil)
        #expect(rewritten.albumIDs == [albumID], "backfill rewrite wiped album membership")

        // And so must the index row it ingested.
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == [albumID])
    }
}
