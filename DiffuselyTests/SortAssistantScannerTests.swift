import Testing
import Foundation
import CryptoKit
@testable import Diffusely

@Suite struct SortAssistantScannerTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func scanSeparatesItemsAlbumsAndIgnoresStateFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let writer = LibraryFileWriter(itemsDirectory: dir)
        let meta = SortAssistantLogicTests.meta(11, prompt: "neon alley")
        let tmp = dir.appendingPathComponent("dl.tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)

        let album = LibraryAlbumFile(id: UUID(), name: "Cyberpunk", createdAt: Date())
        try LibraryAlbumStore(itemsDirectory: dir).write(album)

        try SortAssistantStateStore(itemsDirectory: dir).write(.empty)
        // Corrupt stray JSON must be skipped, not crash the scan.
        try Data("junk".utf8).write(to: dir.appendingPathComponent("999.json"))

        let result = await SortAssistantScanner(itemsDirectory: dir).scan()
        #expect(result.items.map(\.itemID) == [11])
        #expect(result.albums.map(\.id) == [album.id])
    }

    @Test func scanOrdersItemsByIDForDeterministicBatching() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LibraryFileWriter(itemsDirectory: dir)
        for id in [30, 10, 20] {
            let tmp = dir.appendingPathComponent("dl-\(id).tmp"); try Data("b".utf8).write(to: tmp)
            try writer.commit(metadata: SortAssistantLogicTests.meta(id, prompt: "p\(id)"), mediaTempURL: tmp)
        }
        let result = await SortAssistantScanner(itemsDirectory: dir).scan()
        #expect(result.items.map(\.itemID) == [10, 20, 30])
    }

    // MARK: - BE-b: route through the encrypted store

    /// Task BE-b: `scan()`'s bulk enumeration must route through the store
    /// like `LibraryIndexService.reconcile`'s scan already does — an
    /// encrypted+unlocked container must find the same items/albums an
    /// equivalent plaintext container would (and still skip the state file),
    /// not silently see zero opaque `*.m`/`*.x` files.
    @Test func scanFindsSameItemsAndAlbumsEncryptedAsPlaintext() async throws {
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let albumID = UUID()

        func seed(store: LibraryFileStore) throws {
            try store.writeMetadata(
                LibraryItemMetadata.encoder().encode(SortAssistantLogicTests.meta(11, prompt: "neon alley")),
                itemID: 11)
            try LibraryAlbumStore(store: store).write(
                LibraryAlbumFile(id: albumID, name: "Cyberpunk", createdAt: Date()))
            // Shares the item/aux namespace but must never surface as an item
            // or an album row.
            try SortAssistantStateStore(store: store).write(.empty)
        }

        let plainDir = tempDir(); defer { try? FileManager.default.removeItem(at: plainDir) }
        try seed(store: LibraryFileStore(itemsDirectory: plainDir, crypto: nil))
        let plainResult = await SortAssistantScanner(
            itemsDirectory: plainDir, resolveVaultContext: { (.notConfigured, nil) }
        ).scan()

        let cryptoDir = tempDir(); defer { try? FileManager.default.removeItem(at: cryptoDir) }
        try seed(store: LibraryFileStore(itemsDirectory: cryptoDir, crypto: crypto))
        let cryptoResult = await SortAssistantScanner(
            itemsDirectory: cryptoDir, resolveVaultContext: { (.unlocked, crypto) }
        ).scan()

        #expect(plainResult.items.map(\.itemID) == [11])
        #expect(cryptoResult.items.map(\.itemID) == [11])
        #expect(plainResult.albums.map(\.id) == [albumID])
        #expect(cryptoResult.albums.map(\.id) == [albumID])
    }

    /// A configured-but-locked vault has no DEK; `scan()` must return an
    /// empty result rather than scanning with a passthrough store that would
    /// find zero readable sidecars/albums among the real opaque files.
    @Test func scanReturnsEmptyWhenVaultLocked() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(
            LibraryItemMetadata.encoder().encode(SortAssistantLogicTests.meta(1, prompt: "p")), itemID: 1)
        try LibraryAlbumStore(store: store).write(LibraryAlbumFile(id: UUID(), name: "A", createdAt: Date()))

        let result = await SortAssistantScanner(
            itemsDirectory: dir, resolveVaultContext: { (.locked, nil) }
        ).scan()

        #expect(result.items.isEmpty)
        #expect(result.albums.isEmpty)
    }
}
