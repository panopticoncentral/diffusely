import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryAlbumReconcileTests {
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
    private func writeItemSidecar(_ id: Int, albums: [String], in dir: URL) throws {
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t")
        let data = try LibraryItemMetadata.encoder().encode(meta)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }
    private func store_write(_ f: LibraryAlbumFile, in dir: URL) throws {
        try LibraryAlbumStore(itemsDirectory: dir).write(f)
    }

    @Test func reconcileBuildsAlbumRowsFromAlbumFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let a = LibraryAlbumFile(id: UUID(), name: "Faves", createdAt: Date(timeIntervalSince1970: 1))
        try store.write(a)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)
        let ctx = ModelContext(container)
        let albums = try ctx.fetch(FetchDescriptor<PersistedAlbum>())
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Faves")
    }

    @Test func albumFilesAreNotIngestedAsItems() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try store_write(LibraryAlbumFile(id: UUID(), name: "X", createdAt: Date()), in: dir)
        try writeItemSidecar(7, albums: [], in: dir)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)
        let ctx = ModelContext(container)
        let items = try ctx.fetch(FetchDescriptor<PersistedLibraryItem>())
        #expect(items.count == 1)            // only the real item, not the album file
        #expect(items.first?.itemID == 7)
    }

    @Test func reconcilePrunesVanishedAlbumFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let a = LibraryAlbumFile(id: UUID(), name: "Temp", createdAt: Date())
        try store.write(a)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)
        store.delete(id: a.id)
        await index.reconcile(itemsDirectory: dir)
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).isEmpty)
    }

    // MARK: - Album-change reporting (drives LibraryStore.albumsVersion)

    /// `reconcile` returns whether album-relevant state changed so the store can
    /// bump `albumsVersion` — without it, album files/membership synced in from
    /// another device never refresh an open LibraryView (itemCount is unchanged).

    @Test func reconcileReportsChangeWhenAlbumFileAppearsAndQuietWhenNothingChanges() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        // Simulates an album file syncing in from another device.
        try store_write(LibraryAlbumFile(id: UUID(), name: "Synced", createdAt: Date(timeIntervalSince1970: 1)), in: dir)
        #expect(await index.reconcile(itemsDirectory: dir) == true)

        // A reconcile that finds nothing new must stay quiet (no pointless reloads).
        #expect(await index.reconcile(itemsDirectory: dir) == false)
    }

    @Test func reconcileReportsChangeWhenSidecarMembershipSyncsIn() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        // An item with no membership: ingesting it is not an album-state change.
        try writeItemSidecar(7, albums: [], in: dir)
        #expect(await index.reconcile(itemsDirectory: dir) == false)

        // Another device files the item into an album (sidecar rewritten via sync).
        try writeItemSidecar(7, albums: [UUID().uuidString], in: dir)
        #expect(await index.reconcile(itemsDirectory: dir) == true)
        #expect(await index.reconcile(itemsDirectory: dir) == false)
    }

    @Test func reconcileReportsChangeWhenAlbumFileVanishesOrIsRenamed() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        var file = LibraryAlbumFile(id: UUID(), name: "Old", createdAt: Date(timeIntervalSince1970: 1))
        try store.write(file)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        // Rename synced in from another device.
        file.name = "New"
        try store.write(file)
        #expect(await index.reconcile(itemsDirectory: dir) == true)

        // Deletion synced in from another device.
        store.delete(id: file.id)
        #expect(await index.reconcile(itemsDirectory: dir) == true)
        #expect(await index.reconcile(itemsDirectory: dir) == false)
    }

    @Test func reconcileReportsChangeWhenAlbumMemberItemVanishes() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        // A new item arriving already in an album is an album-state change.
        try writeItemSidecar(9, albums: [UUID().uuidString], in: dir)
        #expect(await index.reconcile(itemsDirectory: dir) == true)

        // The member item being deleted on another device empties its album.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("9.json"))
        #expect(await index.reconcile(itemsDirectory: dir) == true)
    }

    @Test func presentButUndecodableAlbumFileIsNotPruned() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let a = LibraryAlbumFile(id: UUID(), name: "Keep", createdAt: Date(timeIntervalSince1970: 1))
        try store.write(a)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)   // row created

        // Corrupt the album file in place (present on disk, but no longer decodable).
        let fileURL = dir.appendingPathComponent(LibraryAlbumStore.fileName(for: a.id))
        try Data("{ not valid album json".utf8).write(to: fileURL)
        await index.reconcile(itemsDirectory: dir)

        // The row must survive because the file is still present; its last-known
        // name is retained (not overwritten by the unreadable file).
        let albums = try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>())
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Keep")
    }
}
