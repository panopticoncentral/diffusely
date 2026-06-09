import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryAlbumServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Commit a real item (media + sidecar) so add/remove can read it back.
    private func commitItem(_ id: Int, in dir: URL) throws {
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t")
        let tmp = dir.appendingPathComponent("dl.tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)
    }

    @Test func createAlbumWritesFileAndIndexRow() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let id = await svc.createAlbum(name: "Faves")
        let read = try #require(LibraryAlbumStore(itemsDirectory: dir).read(id: id))
        #expect(read.name == "Faves")
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).count == 1)
    }

    @Test func addThenRemoveItemUpdatesSidecarAndIndex() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        try commitItem(11, in: dir)
        await index.reconcile(itemsDirectory: dir)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let album = await svc.createAlbum(name: "A")
        await svc.addItems([11], toAlbum: album)
        let writer = LibraryFileWriter(itemsDirectory: dir)
        #expect(writer.readMetadata(itemID: 11)?.albumIDs == [album.uuidString])
        await svc.removeItems([11], fromAlbum: album)
        #expect(writer.readMetadata(itemID: 11)?.albumIDs == [])
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == [])
    }

    @Test func deleteAlbumRemovesFileButKeepsItemMedia() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        try commitItem(12, in: dir)
        await index.reconcile(itemsDirectory: dir)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let album = await svc.createAlbum(name: "Temp")
        await svc.addItems([12], toAlbum: album)
        await svc.deleteAlbum(album)
        #expect(LibraryAlbumStore(itemsDirectory: dir).read(id: album) == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("12.jpeg").path))
        #expect(LibraryFileWriter(itemsDirectory: dir).readMetadata(itemID: 12) != nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).isEmpty)
    }

    @Test func renameAlbumRewritesFileAndIndex() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let album = await svc.createAlbum(name: "Old")
        await svc.renameAlbum(album, to: "New")
        #expect(LibraryAlbumStore(itemsDirectory: dir).read(id: album)?.name == "New")
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).first?.name == "New")
    }
}
