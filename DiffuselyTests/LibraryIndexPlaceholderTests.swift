import Testing
import Foundation
import CryptoKit
import SwiftData
@testable import Diffusely

/// A sidecar that iCloud has evicted (or not yet materialized) is present in the
/// directory listing but unreadable without forcing a blocking FileProvider
/// download. `scanContainer` therefore skips reading it — and anything missing
/// from `seenIDs`/`seenAlbumIDs` is pruned by `reconcile` as "the file vanished".
///
/// Plaintext recovers the id from the `{id}.json` stem with no I/O, so its rows
/// survive. Encrypted names are opaque HMAC tokens, so encrypted rows were
/// dropped instead — and because macOS evicts iCloud content in sweeps, an
/// eviction sweep over the container deleted the entire index at once, which the
/// app then rebuilt file-by-file as the sidecars re-downloaded. `fileToken` is
/// deterministic, so an evicted sidecar's id IS recoverable: hash the ids the
/// index already holds and match the token. These tests drive that resolution
/// through the injectable `isPlaceholder` seam, since the real check reads live
/// iCloud resource values that a temp directory can't produce.
@Suite struct LibraryIndexPlaceholderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func metadataJSON(itemID: Int) throws -> Data {
        try LibraryItemMetadata.encoder().encode(makeMeta(itemID: itemID))
    }

    private func makeMeta(itemID: Int) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: itemID,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 10, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t"
        )
    }

    @Test func encryptedPlaceholderSidecarKeepsItsIndexRow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(metadataJSON(itemID: 1), itemID: 1)
        try store.writeMetadata(metadataJSON(itemID: 2), itemID: 2)

        // Item 2's sidecar is evicted this round; item 1's is materialized.
        let evicted = crypto.fileName(itemID: 2, role: .meta)
        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            indexedItemIDs: [1, 2],
            isPlaceholder: { $0.lastPathComponent == evicted }
        ))

        #expect(scan.seenIDs == Set([1, 2]), "an evicted sidecar must not prune the row it belongs to")
        #expect(scan.items.map(\.metadata.itemID) == [1], "only the materialized sidecar is re-read")
    }

    @Test func encryptedPlaceholderSidecarUnknownToTheIndexIsNotInvented() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(metadataJSON(itemID: 7), itemID: 7)

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            indexedItemIDs: [1, 2],
            isPlaceholder: { _ in true }
        ))

        #expect(scan.seenIDs.isEmpty, "a token matching no indexed id resolves to nothing, not a guess")
    }

    @Test func encryptedPlaceholderAuxFileKeepsItsAlbumRow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let albumID = UUID()
        let album = LibraryAlbumFile(id: albumID, name: "Favorites", createdAt: Date())
        // Written through the production album store so the opaque `.x` token
        // is derived from the same logical name reconcile has to match.
        try LibraryAlbumStore(store: store).write(album)

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            indexedAlbumIDs: [albumID],
            isPlaceholder: { _ in true }
        ))

        #expect(scan.seenAlbumIDs == Set([albumID]), "an evicted album file must not prune its row")
        #expect(scan.albums.isEmpty, "an evicted album file is not readable, so nothing refreshes name/createdAt")
    }

    /// The reverse token maps are only as good as the ids reconcile hands the
    /// scan, so the index has to be able to report what it currently holds.
    @Test func indexedIDsReportsEveryItemAndAlbumRowTheIndexHolds() async throws {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let index = LibraryIndexService(modelContainer: container)
        let albumID = UUID()
        await index.ingest(metadata: makeMeta(itemID: 11), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMeta(itemID: 12), downloadStatus: .evicted)
        await index.upsertAlbum(LibraryAlbumFile(id: albumID, name: "A", createdAt: Date()))

        let known = await index.indexedIDs()

        #expect(known.items == Set([11, 12]))
        #expect(known.albums == Set([albumID]))
    }

    /// A materialized file that can't be READ or DECODED this round is still
    /// present — it has not vanished. The album branch already refused to prune
    /// on "placeholder, transient read error, or corrupt JSON"; item sidecars
    /// fell through to the same `continue` that pruned them.
    @Test func encryptedUnreadableSidecarKeepsItsIndexRow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(metadataJSON(itemID: 1), itemID: 1)
        // Item 2's sidecar is materialized but its bytes don't open: a torn
        // write, a coordination failure, or corruption. Not a deletion.
        try Data("not a DFEB envelope".utf8)
            .write(to: dir.appendingPathComponent(crypto.fileName(itemID: 2, role: .meta)))

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            indexedItemIDs: [1, 2],
            isPlaceholder: { _ in false }
        ))

        #expect(scan.seenIDs == Set([1, 2]), "an unreadable sidecar must not prune the row it belongs to")
        #expect(scan.items.map(\.metadata.itemID) == [1], "only the readable sidecar is ingested")
    }

    @Test func plaintextUndecodableSidecarKeepsItsIndexRow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try Data("{ truncated".utf8).write(to: dir.appendingPathComponent("5.json"))

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            isPlaceholder: { _ in false }
        ))

        #expect(scan.seenIDs == Set([5]))
        #expect(scan.items.isEmpty)
    }

    @Test func encryptedUnreadableAuxFileKeepsItsAlbumRow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let albumID = UUID()
        try Data("not a DFEB envelope".utf8)
            .write(to: dir.appendingPathComponent(
                crypto.fileName(auxName: LibraryAlbumStore.fileName(for: albumID))))

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            indexedAlbumIDs: [albumID],
            isPlaceholder: { _ in false }
        ))

        #expect(scan.seenAlbumIDs == Set([albumID]), "an unreadable album file must not prune its row")
        #expect(scan.albums.isEmpty)
    }

    /// The other half of the contract: an aux blob that simply isn't an album
    /// (sort-assistant state shares the `.x` namespace) must stay skipped — it
    /// has no album row, so nothing to preserve and nothing to invent.
    @Test func encryptedNonAlbumAuxFileIsStillSkipped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeAux(Data("{\"notAnAlbum\":true}".utf8), name: "sort-assistant-state")

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            indexedAlbumIDs: [UUID()],
            isPlaceholder: { _ in false }
        ))

        #expect(scan.seenAlbumIDs.isEmpty)
        #expect(scan.albums.isEmpty)
    }

    /// The cache limit evicts media by name. Sidecars record the PLAINTEXT
    /// `{itemID}.{ext}` name, which in an encrypted container is not the file on
    /// disk (`{token}.b`) — so eviction aimed at a path that never exists and
    /// silently freed nothing, leaving the container to outgrow its limit until
    /// macOS evicted it instead, indiscriminately and including the sidecars.
    @Test func encryptedEvictionTargetsTheOpaqueMediaFileNotThePlaintextName() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)

        let urls = LibraryIndexService.mediaURLsToEvict(
            victims: [(itemID: 4, plaintextExtension: "jpeg")], store: store)

        #expect(urls == [dir.appendingPathComponent(crypto.fileName(itemID: 4, role: .media))])
    }

    @Test func plaintextEvictionTargetsTheLegacyMediaName() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)

        let urls = LibraryIndexService.mediaURLsToEvict(
            victims: [(itemID: 4, plaintextExtension: "mp4")], store: store)

        #expect(urls == [dir.appendingPathComponent("4.mp4")])
    }

    @Test func plaintextPlaceholderSidecarKeepsItsIndexRowWithoutTheIndexsHelp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(metadataJSON(itemID: 5), itemID: 5)

        // No `indexedItemIDs`: plaintext recovers the id from the filename stem.
        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            isPlaceholder: { _ in true }
        ))

        #expect(scan.seenIDs == Set([5]))
    }
}
