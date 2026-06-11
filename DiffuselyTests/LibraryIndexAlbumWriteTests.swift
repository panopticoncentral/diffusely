import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryIndexAlbumWriteTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
    private func ingest(_ index: LibraryIndexService, id: Int, albums: [String]) async {
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t")
        await index.ingest(metadata: meta, downloadStatus: .downloaded)
    }

    @Test func upsertRenameDeleteAlbum() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let id = UUID()
        await index.upsertAlbum(LibraryAlbumFile(id: id, name: "A", createdAt: Date(timeIntervalSince1970: 1)))
        await index.upsertAlbum(LibraryAlbumFile(id: id, name: "A2", createdAt: Date(timeIntervalSince1970: 1)))
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).first?.name == "A2")
        await index.removeAlbum(id: id)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).isEmpty)
    }

    @Test func setAlbumIDsUpdatesRow() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await ingest(index, id: 5, albums: [])
        await index.setAlbumIDs(itemID: 5, albumIDs: ["A", "B"])
        let ctx = ModelContext(container)
        let row = try #require(ctx.fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == ["A", "B"])
    }
}
