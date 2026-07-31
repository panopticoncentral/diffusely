import Testing
import Foundation
import CryptoKit
import SwiftData
@testable import Diffusely

/// Task 11b: reconcile/rebuild must produce the same index rows whether the
/// container is plaintext or encrypted, and must never touch the index while
/// the vault is locked. These tests drive `LibraryIndexService.scanContainer(store:)`
/// and `applyScan` directly rather than the actor's `reconcile(itemsDirectory:)`
/// entry point, because the locked/unlocked crypto that entry point picks up
/// comes from the process-wide `LibraryVaultProvider.shared` singleton — not
/// safely re-configurable per test without leaking state into unrelated tests
/// that run in the same process. `scanContainer(store:)` and `applyScan` are
/// exactly the two pieces `reconcile` composes, so exercising them directly
/// gives full coverage of the encrypted-aware classification without that risk.
@Suite struct LibraryIndexEncryptedTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMeta(itemID: Int, albumIDs: [String] = []) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: itemID,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 10, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albumIDs, savedAt: Date(), savedByAppVersion: "t"
        )
    }

    /// Writes 2 items (item 1 in `albumID`, item 2 in none) + the album file
    /// through `store`, in whichever on-disk shape matches its mode (opaque
    /// `.m`/`.b`/`.x` when encrypted, legacy `{id}.json`/`.jpeg` +
    /// `album-{uuid}.json` when not), plus — encrypted only — a same-namespace
    /// aux blob that must NOT decode as an album (stands in for a future
    /// sort-assistant-state file). Returns the resulting scan.
    private func writeAndScan(store: LibraryFileStore, albumID: UUID) throws -> LibraryIndexService.ScanResult? {
        try store.writeMetadata(LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1, albumIDs: [albumID.uuidString])), itemID: 1)
        try store.writeMedia(Data("img1".utf8), itemID: 1, plaintextExtension: "jpeg")
        try store.writeMetadata(LibraryItemMetadata.encoder().encode(makeMeta(itemID: 2)), itemID: 2)
        try store.writeMedia(Data("img2".utf8), itemID: 2, plaintextExtension: "jpeg")

        let album = LibraryAlbumFile(id: albumID, name: "Favorites", createdAt: Date())
        if store.isEncrypted {
            try store.writeAux(LibraryAlbumFile.encoder().encode(album), name: "album-\(albumID.uuidString)")
            // Shares the `.x` namespace but isn't a LibraryAlbumFile — must be
            // skipped, not mistaken for a second album row.
            try store.writeAux(Data("{\"notAnAlbum\":true}".utf8), name: "sort-assistant-state")
        } else {
            try LibraryAlbumStore(itemsDirectory: store.itemsDirectory).write(album)
        }

        return LibraryIndexService.scanContainer(store: store)
    }

    @Test func encryptedScanMatchesPlaintextScan() throws {
        let albumID = UUID()

        let plainDir = tempDir()
        defer { try? FileManager.default.removeItem(at: plainDir) }
        let plainScanOrNil = try writeAndScan(store: LibraryFileStore(itemsDirectory: plainDir, crypto: nil), albumID: albumID)
        let plainScan = try #require(plainScanOrNil)

        let cryptoDir = tempDir()
        defer { try? FileManager.default.removeItem(at: cryptoDir) }
        let cryptoStore = LibraryFileStore(itemsDirectory: cryptoDir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let cryptoScanOrNil = try writeAndScan(store: cryptoStore, albumID: albumID)
        let cryptoScan = try #require(cryptoScanOrNil)

        #expect(plainScan.seenIDs == Set([1, 2]))
        #expect(plainScan.seenIDs == cryptoScan.seenIDs)
        #expect(Set(plainScan.items.map(\.metadata.itemID)) == Set(cryptoScan.items.map(\.metadata.itemID)))
        #expect(plainScan.items.allSatisfy { $0.status == .downloaded })
        #expect(cryptoScan.items.allSatisfy { $0.status == .downloaded }, "encrypted media lookup must resolve the opaque .b path, not the plaintext mediaFileName")

        #expect(plainScan.seenAlbumIDs == [albumID])
        #expect(cryptoScan.seenAlbumIDs == [albumID])
        #expect(cryptoScan.albums.count == 1, "the sort-assistant-state-shaped aux file must not be classified as an album")
        #expect(plainScan.albums.map(\.name) == cryptoScan.albums.map(\.name))
    }

    @Test func encryptedReconcileProducesSameIndexRowsAsPlaintext() async throws {
        let albumID = UUID()

        func buildIndex(store: LibraryFileStore) async throws -> (items: [(itemID: Int, albumIDs: [String])], albums: [(id: UUID, name: String)]) {
            let scanOrNil = try writeAndScan(store: store, albumID: albumID)
            let scan = try #require(scanOrNil)
            let container = try ModelContainer(
                for: PersistedLibraryItem.self, PersistedAlbum.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
            let index = LibraryIndexService(modelContainer: container)
            let epoch = await index.currentMutationEpoch()
            let applied = await index.applyScan(scan, ifEpochMatches: epoch)
            #expect(applied.wasApplied)
            let ctx = ModelContext(container)
            let items = try ctx.fetch(FetchDescriptor<PersistedLibraryItem>())
                .sorted { $0.itemID < $1.itemID }
                .map { (itemID: $0.itemID, albumIDs: $0.albumIDs) }
            let albums = try ctx.fetch(FetchDescriptor<PersistedAlbum>()).map { (id: $0.id, name: $0.name) }
            return (items, albums)
        }

        let plainDir = tempDir()
        defer { try? FileManager.default.removeItem(at: plainDir) }
        let plainResult = try await buildIndex(store: LibraryFileStore(itemsDirectory: plainDir, crypto: nil))

        let cryptoDir = tempDir()
        defer { try? FileManager.default.removeItem(at: cryptoDir) }
        let cryptoResult = try await buildIndex(store: LibraryFileStore(itemsDirectory: cryptoDir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256))))

        #expect(plainResult.items.map(\.itemID) == cryptoResult.items.map(\.itemID))
        #expect(plainResult.items.map(\.albumIDs) == cryptoResult.items.map(\.albumIDs))
        #expect(plainResult.albums.map(\.id) == cryptoResult.albums.map(\.id))
        #expect(plainResult.albums.map(\.name) == cryptoResult.albums.map(\.name))
    }

    // MARK: - Locked-reconcile guard

    /// `reconcile`'s locked check delegates to this pure function — proven
    /// directly here since driving the real singleton (`LibraryVaultProvider.shared`)
    /// into `.locked` would leak global state into every other test in the
    /// process. See the type-level doc comment.
    @Test func shouldReconcileBlocksOnlyLockedState() {
        #expect(LibraryIndexService.shouldReconcile(givenVaultState: .notConfigured) == true)
        #expect(LibraryIndexService.shouldReconcile(givenVaultState: .unlocked) == true)
        #expect(LibraryIndexService.shouldReconcile(givenVaultState: .locked) == false)
    }

    // MARK: - Delete through the store (LibraryStore.deleteItemFiles)

    @Test func deleteItemFilesRemovesEncryptedFilesRegardlessOfExtensionGuessed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        try store.writeMetadata(Data("{}".utf8), itemID: 9)
        // Real media type is video; `deleteItemFiles` tries "jpeg" first.
        try store.writeMedia(Data("video".utf8), itemID: 9, plaintextExtension: "mp4")

        LibraryStore.deleteItemFiles(itemIDs: [9], store: store)

        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.isEmpty, "encrypted meta+media must be removed even though the caller guessed the wrong extension first")
    }

    @Test func deleteItemFilesPlaintextLeavesOtherItemsUntouched() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(Data("{}".utf8), itemID: 1)
        try store.writeMedia(Data("a".utf8), itemID: 1, plaintextExtension: "jpeg")
        try store.writeMetadata(Data("{}".utf8), itemID: 2)
        try store.writeMedia(Data("a".utf8), itemID: 2, plaintextExtension: "mp4")

        LibraryStore.deleteItemFiles(itemIDs: [1], store: store)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("2.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("2.mp4").path))
    }
}
