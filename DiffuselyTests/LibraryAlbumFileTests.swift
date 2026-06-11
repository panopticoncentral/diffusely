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

    @Test func decodesLegacyFileWithoutProfileFields() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Faves","createdAt":"2026-01-01T00:00:00Z"}
        """
        let file = try LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: Data(json.utf8))
        #expect(file.id == id)
        #expect(file.userDescription == nil)
        #expect(file.aiProfile == nil)
    }

    @Test func profileFieldsRoundTripThroughStore() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        var file = LibraryAlbumFile(id: UUID(), name: "Cyberpunk", createdAt: Date(timeIntervalSince1970: 10))
        file.userDescription = "Neon city scenes"
        file.aiProfile = AlbumAIProfile(text: "Futuristic neon cityscapes…",
                                        builtAt: Date(timeIntervalSince1970: 20),
                                        memberCount: 42)
        try store.write(file)
        let read = try #require(store.read(id: file.id))
        #expect(read.userDescription == "Neon city scenes")
        #expect(read.aiProfile?.memberCount == 42)
        #expect(read == file)
    }
}
