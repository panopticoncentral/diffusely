import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// End-to-end repro of the reported bug flow: in "Not in any Album", add batch 1
/// to album A (they disappear), reconcile (the app runs a debounced one after
/// every sidecar write), then add batch 2 to album B — batch 1 must stay gone.
/// Mirrors the app exactly: ON-DISK store, the long-lived `container.mainContext`
/// read through `LibrarySortService`, real sidecar files, and the
/// `LibraryIndexService` @ModelActor doing the writes. The deterministic
/// write-during-scan race itself is covered in `AlbumMembershipClobberTests`.
@MainActor
@Suite struct AlbumReappearReproTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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
        let tmp = dir.appendingPathComponent("dl-\(id).tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)
    }

    private func notInAnyAlbumIDs(_ sortService: LibrarySortService) -> Set<Int> {
        guard case .flat(let items) = sortService.sortedLibraryContent(sort: .dateNewest, filter: .notInAnyAlbum) else {
            return []
        }
        return Set(items.map { $0.itemID })
    }

    @Test func secondAddDoesNotResurrectFirstBatch() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
        let mainContext = container.mainContext
        let sortService = LibrarySortService(modelContext: mainContext)

        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })

        for id in 1...4 { try commitItem(id, in: dir) }
        await index.reconcile(itemsDirectory: dir)

        // View mount: realize every item in the main context (the grid does this).
        #expect(notInAnyAlbumIDs(sortService) == [1, 2, 3, 4])

        // Add #1: batch [1, 2] -> album A. Reload: they disappear.
        let albumA = await albumService.createAlbum(name: "A")
        await albumService.addItems([1, 2], toAlbum: albumA)
        #expect(notInAnyAlbumIDs(sortService) == [3, 4], "after first add, batch 1 should be gone")

        // The debounced reconcile triggered by add #1's sidecar writes.
        await index.reconcile(itemsDirectory: dir)

        // Add #2: batch [3] -> album B. Reload: bug said [1, 2] reappeared here.
        let albumB = await albumService.createAlbum(name: "B")
        await albumService.addItems([3], toAlbum: albumB)
        #expect(notInAnyAlbumIDs(sortService) == [4], "after second add, batch 1 must stay gone")

        // "Go away and come back": a fresh context sees the truth.
        let freshIDs = Set(
            (try ModelContext(container).fetch(FetchDescriptor<PersistedLibraryItem>()))
                .filter { $0.albumIDs.isEmpty }
                .map { $0.itemID }
        )
        #expect(freshIDs == [4])
    }
}
