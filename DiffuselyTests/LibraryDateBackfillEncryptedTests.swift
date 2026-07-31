import Testing
import Foundation
import CryptoKit
@testable import Diffusely

/// Task 11c: `FileLibraryBackfillSidecarStore.rewriteMetadata` must route
/// through the encrypted-aware store when unlocked, and must never write
/// plaintext into an encrypted-but-locked container. Its `resolveVaultContext`
/// seam lets these tests drive `.unlocked`/`.locked` directly instead of the
/// process-wide `LibraryVaultProvider.shared` singleton — see the precedent
/// documented on `LibraryIndexEncryptedTests` for why driving the real
/// singleton into `.locked` is avoided in this test suite.
@Suite struct LibraryDateBackfillEncryptedTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMeta(
        itemID: Int, publishedAt: Date?, attemptedAt: Date? = nil
    ) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: itemID,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: publishedAt,
            publishedAtBackfillAttemptedAt: attemptedAt,
            savedAt: Date(), savedByAppVersion: "t")
    }

    @Test func rewriteMetadataRoundTripsThroughEncryptedStore() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let cryptoStore = LibraryFileStore(itemsDirectory: dir, crypto: crypto)

        let original = makeMeta(itemID: 42, publishedAt: nil)
        try cryptoStore.writeMetadata(
            LibraryItemMetadata.encoder().encode(original), itemID: 42)

        let sidecarStore = FileLibraryBackfillSidecarStore(
            itemsDirectory: dir,
            resolveVaultContext: { (.unlocked, crypto) }
        )
        let updated = makeMeta(itemID: 42, publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await sidecarStore.rewriteMetadata(updated)

        // On disk: opaque `.m`, never the legacy literal `42.json`.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("42.json").path))
        let onDisk = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(onDisk.allSatisfy { $0.lastPathComponent.hasSuffix(".m") })

        let read = try #require(LibraryFileWriter(store: cryptoStore).readMetadata(itemID: 42))
        #expect(read.publishedAt != nil)
    }

    @Test func rewriteMetadataThrowsAndSkipsWriteWhenVaultLocked() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        // A pre-existing plaintext sidecar — stands in for "the container is
        // configured but currently locked", where writing through a
        // passthrough store would silently produce plaintext.
        let original = makeMeta(itemID: 1, publishedAt: nil)
        try LibraryItemMetadata.encoder().encode(original)
            .write(to: dir.appendingPathComponent("1.json"))

        let sidecarStore = FileLibraryBackfillSidecarStore(
            itemsDirectory: dir,
            resolveVaultContext: { (.locked, nil) }
        )
        let updated = makeMeta(itemID: 1, publishedAt: Date())

        await #expect(throws: LibraryBackfillSidecarStoreError.vaultLocked) {
            try await sidecarStore.rewriteMetadata(updated)
        }

        // The existing sidecar must be untouched — still no publishedAt.
        let data = try Data(contentsOf: dir.appendingPathComponent("1.json"))
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.publishedAt == nil)
        // No new opaque file was created either.
        let onDisk = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(onDisk.map(\.lastPathComponent) == ["1.json"])
    }

    // MARK: - BE-b: pendingItems() bulk scan

    /// Task BE-b: `pendingItems()`'s bulk enumeration must route through the
    /// store like `rewriteMetadata` already does — an encrypted+unlocked
    /// container must find the same pending items an equivalent plaintext
    /// container would, not silently see zero opaque `*.m` files.
    @Test func pendingItemsFindsSameItemsEncryptedAsPlaintext() async throws {
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))

        func seed(store: LibraryFileStore) throws {
            // Item 1: missing publishedAt → pending.
            try store.writeMetadata(
                LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1, publishedAt: nil)), itemID: 1)
            // Item 2: already has publishedAt → not pending.
            try store.writeMetadata(
                LibraryItemMetadata.encoder().encode(makeMeta(itemID: 2, publishedAt: Date())), itemID: 2)
            // Item 3: missing publishedAt but already attempted → not pending.
            let attempted = makeMeta(itemID: 3, publishedAt: nil, attemptedAt: Date())
            try store.writeMetadata(LibraryItemMetadata.encoder().encode(attempted), itemID: 3)
        }

        let plainDir = tempDir(); defer { try? FileManager.default.removeItem(at: plainDir) }
        try seed(store: LibraryFileStore(itemsDirectory: plainDir, crypto: nil))
        let plainStore = FileLibraryBackfillSidecarStore(
            itemsDirectory: plainDir, resolveVaultContext: { (.notConfigured, nil) })
        let plainPending = try await plainStore.pendingItems()

        let cryptoDir = tempDir(); defer { try? FileManager.default.removeItem(at: cryptoDir) }
        try seed(store: LibraryFileStore(itemsDirectory: cryptoDir, crypto: crypto))
        let cryptoStore = FileLibraryBackfillSidecarStore(
            itemsDirectory: cryptoDir, resolveVaultContext: { (.unlocked, crypto) })
        let cryptoPending = try await cryptoStore.pendingItems()

        #expect(plainPending.map(\.itemID) == [1])
        #expect(cryptoPending.map(\.itemID) == [1])
    }

    /// A configured-but-locked vault has no DEK; `pendingItems()` must return
    /// empty rather than scanning with a passthrough store that would find
    /// zero `*.json` sidecars among the real opaque `*.m` files.
    @Test func pendingItemsReturnsEmptyWhenVaultLocked() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        try LibraryFileStore(itemsDirectory: dir, crypto: crypto).writeMetadata(
            LibraryItemMetadata.encoder().encode(makeMeta(itemID: 5, publishedAt: nil)), itemID: 5)

        let store = FileLibraryBackfillSidecarStore(
            itemsDirectory: dir, resolveVaultContext: { (.locked, nil) })
        let pending = try await store.pendingItems()

        #expect(pending.isEmpty)
    }
}
