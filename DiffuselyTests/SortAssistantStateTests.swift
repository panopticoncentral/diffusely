import Testing
import Foundation
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
}
