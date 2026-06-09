import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryAlbumFileTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func fileNameFollowsAlbumUUIDConvention() {
        let id = UUID()
        #expect(LibraryAlbumStore.fileName(for: id) == "album-\(id.uuidString).json")
        #expect(LibraryAlbumStore.albumID(fromFileName: "album-\(id.uuidString).json") == id)
        #expect(LibraryAlbumStore.albumID(fromFileName: "1234.json") == nil)
    }

    @Test func writeThenReadRoundTrips() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let file = LibraryAlbumFile(id: UUID(), name: "Sci-fi", createdAt: Date(timeIntervalSince1970: 10))
        try store.write(file)
        let read = try #require(store.read(id: file.id))
        #expect(read == file)
    }

    @Test func deleteRemovesFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let file = LibraryAlbumFile(id: UUID(), name: "Temp", createdAt: Date())
        try store.write(file)
        store.delete(id: file.id)
        #expect(store.read(id: file.id) == nil)
    }
}
