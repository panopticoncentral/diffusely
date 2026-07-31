import Testing
import Foundation
import CryptoKit
import SwiftData
@testable import Diffusely

/// Task 11c: album files and item-membership sidecar rewrites must route
/// through the encrypted-aware store when unlocked, and must never write
/// plaintext into an encrypted-but-locked container. `LibraryAlbumService`'s
/// `resolveVaultContext` seam lets these tests drive `.unlocked`/`.locked`
/// directly instead of the process-wide `LibraryVaultProvider.shared`
/// singleton — driving the real singleton into `.locked` would leak global
/// state into every other test in the process (see the precedent documented
/// on `LibraryIndexEncryptedTests`).
@Suite struct LibraryAlbumServiceEncryptedTests {
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

    // MARK: - Encrypted round trip

    @Test func createReadDeleteRoundTripThroughEncryptedStore() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let svc = LibraryAlbumService(
            index: index,
            itemsDirectory: { dir },
            resolveVaultContext: { (.unlocked, crypto) }
        )

        let id = await svc.createAlbum(name: "Cyberpunk")

        // On disk: opaque `.x`, never the legacy literal `album-<uuid>.json`.
        let onDisk = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!onDisk.isEmpty)
        #expect(onDisk.allSatisfy { $0.lastPathComponent.hasSuffix(".x") })
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LibraryAlbumStore.fileName(for: id)).path))

        // Decrypts back through an independently-constructed encrypted store.
        let cryptoStore = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let read = try #require(LibraryAlbumStore(store: cryptoStore).read(id: id))
        #expect(read.name == "Cyberpunk")
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).count == 1)

        // Rename rewrites the same opaque file, still decryptable.
        await svc.renameAlbum(id, to: "Neon City")
        #expect(LibraryAlbumStore(store: cryptoStore).read(id: id)?.name == "Neon City")

        await svc.deleteAlbum(id)
        #expect(LibraryAlbumStore(store: cryptoStore).read(id: id) == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).isEmpty)
    }

    @Test func membershipRewriteRoundTripsThroughEncryptedStore() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let cryptoStore = LibraryFileStore(itemsDirectory: dir, crypto: crypto)

        // Commit the item directly through the same encrypted store so its
        // sidecar is already opaque before the service touches it.
        let meta = LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: 7, sourcePostID: nil,
            sourcePostTitle: nil, canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "7.jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t")
        try cryptoStore.writeMetadata(LibraryItemMetadata.encoder().encode(meta), itemID: 7)
        try cryptoStore.writeMedia(Data("img".utf8), itemID: 7, plaintextExtension: "jpeg")

        let svc = LibraryAlbumService(
            index: index,
            itemsDirectory: { dir },
            resolveVaultContext: { (.unlocked, crypto) }
        )
        let albumID = await svc.createAlbum(name: "A")
        await svc.addItems([7], toAlbum: albumID)

        #expect(LibraryFileWriter(store: cryptoStore).readMetadata(itemID: 7)?.albumIDs == [albumID.uuidString])
        // No plaintext `7.json` leaked to disk.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("7.json").path))

        await svc.removeItems([7], fromAlbum: albumID)
        #expect(LibraryFileWriter(store: cryptoStore).readMetadata(itemID: 7)?.albumIDs == [])
    }

    // MARK: - Locked-vault guard

    /// A locked vault must skip every album mutation as a no-op — never
    /// falling back to writing plaintext into what is really an encrypted
    /// container, and never touching a pre-existing (encrypted) album file.
    @Test func lockedVaultSkipsAlbumMutationsWithoutTouchingDisk() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let cryptoStore = LibraryFileStore(itemsDirectory: dir, crypto: crypto)

        // Set up one real (encrypted) album and one real (encrypted) item
        // while unlocked.
        let unlockedSvc = LibraryAlbumService(
            index: index, itemsDirectory: { dir }, resolveVaultContext: { (.unlocked, crypto) })
        let albumID = await unlockedSvc.createAlbum(name: "Before Lock")

        let meta = LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: 1, sourcePostID: nil,
            sourcePostTitle: nil, canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "1.jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t")
        try cryptoStore.writeMetadata(LibraryItemMetadata.encoder().encode(meta), itemID: 1)
        try cryptoStore.writeMedia(Data("img".utf8), itemID: 1, plaintextExtension: "jpeg")
        // Ingest the row directly rather than a full `index.reconcile`: reconcile
        // reads its crypto from the process-wide `LibraryVaultProvider.shared`
        // (which stays `.notConfigured`/plaintext in this test process), so
        // scanning this encrypted-only directory with it would find nothing and
        // prune the album row `unlockedSvc.createAlbum` just wrote.
        await index.ingest(metadata: meta, downloadStatus: .downloaded)

        let filesAfterSetup = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(filesAfterSetup.count == 3, "1 album file + 1 item sidecar + 1 media file")

        // Now simulate the vault being locked for every subsequent operation.
        let lockedSvc = LibraryAlbumService(
            index: index, itemsDirectory: { dir }, resolveVaultContext: { (.locked, nil) })

        let newID = await lockedSvc.createAlbum(name: "Should Not Persist")
        await lockedSvc.renameAlbum(albumID, to: "Renamed While Locked")
        await lockedSvc.deleteAlbum(albumID)
        await lockedSvc.addItems([1], toAlbum: albumID)

        // Disk is byte-for-byte unchanged: same set of opaque files as after
        // setup — no new file for the new album, no rewritten item sidecar.
        let filesAfterLockedAttempts = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        #expect(Set(filesAfterLockedAttempts.map(\.lastPathComponent)) == Set(filesAfterSetup.map(\.lastPathComponent)))

        #expect(LibraryAlbumStore(store: cryptoStore).read(id: newID) == nil, "locked create must not write a file")
        #expect(LibraryAlbumStore(store: cryptoStore).read(id: albumID)?.name == "Before Lock", "locked rename must not touch the existing file")
        #expect(LibraryAlbumStore(store: cryptoStore).read(id: albumID) != nil, "locked delete must not remove the existing file")
        #expect(LibraryFileWriter(store: cryptoStore).readMetadata(itemID: 1)?.albumIDs == [], "locked addItems must not rewrite the item sidecar")

        // Index untouched by the locked attempts: still just the one album row
        // from setup, and item 1's membership still empty.
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).count == 1)
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == [])
    }
}
