import Testing
import Foundation
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
}
