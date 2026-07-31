import Testing
import Foundation
import CryptoKit
@testable import Diffusely

@Suite struct SortAssistantStateTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func rejectionRecordingAndLookup() {
        var state = SortAssistantState.empty
        let album = UUID()
        #expect(!state.isRejected(itemID: 5, albumID: album))
        state.recordRejection(itemID: 5, albumID: album)
        state.recordRejection(itemID: 5, albumID: album)   // idempotent
        #expect(state.isRejected(itemID: 5, albumID: album))
        #expect(!state.isRejected(itemID: 6, albumID: album))
        #expect(state.rejected["5"] == [album.uuidString])

        #expect(!state.isNewAlbumRejected(itemID: 5))
        state.recordNewAlbumRejection(itemID: 5)
        state.recordNewAlbumRejection(itemID: 5)           // idempotent
        #expect(state.isNewAlbumRejected(itemID: 5))
        #expect(state.rejectedNewAlbum == ["5"])
    }

    @Test func storeRoundTripsAndDefaultsToEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SortAssistantStateStore(itemsDirectory: dir)
        #expect(store.read() == .empty)            // missing file

        var state = SortAssistantState.empty
        state.recordRejection(itemID: 11, albumID: UUID())
        try store.write(state)
        #expect(store.read() == state)
    }

    @Test func corruptFileReadsAsEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(
            to: dir.appendingPathComponent(SortAssistantStateStore.fileName))
        #expect(SortAssistantStateStore(itemsDirectory: dir).read() == .empty)
    }

    /// Task 11c: routed through `LibraryFileStore`'s aux helpers, the state
    /// file must round-trip through an encrypted store as an opaque `.x`
    /// file, never the legacy literal `sort-assistant-state.json` name.
    @Test func encryptedStoreRoundTripsAndIsOpaqueOnDisk() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = SortAssistantStateStore(store: LibraryFileStore(itemsDirectory: dir, crypto: crypto))

        var state = SortAssistantState.empty
        state.recordRejection(itemID: 11, albumID: UUID())
        try store.write(state)

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(SortAssistantStateStore.fileName).path))
        let onDisk = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(onDisk.allSatisfy { $0.lastPathComponent.hasSuffix(".x") })
        #expect(store.read() == state)
    }
}
