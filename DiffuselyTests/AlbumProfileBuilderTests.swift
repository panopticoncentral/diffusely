import Testing
import Foundation
@testable import Diffusely

@Suite struct AlbumProfileBuilderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func commitItem(_ id: Int, prompt: String?, albumIDs: [String] = [], in dir: URL) throws {
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let meta = SortAssistantLogicTests.meta(id, prompt: prompt, albumIDs: albumIDs)
        let tmp = dir.appendingPathComponent("dl-\(id).tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)
    }

    @Test func buildsProfileFromMemberPromptsOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let albumID = UUID()
        try commitItem(1, prompt: "neon alley", albumIDs: [albumID.uuidString], in: dir)
        try commitItem(2, prompt: "chrome android", albumIDs: [albumID.uuidString], in: dir)
        try commitItem(3, prompt: nil, albumIDs: [albumID.uuidString], in: dir)   // promptless member
        try commitItem(4, prompt: "castle on a hill", in: dir)                    // non-member

        let captured = CapturedMessages()
        let stub = StubClassifier { system, user in
            await captured.record(system: system, user: user)
            return #"{"profile":"Neon cityscapes"}"#
        }
        let builder = AlbumProfileBuilder(itemsDirectory: dir, classifier: stub)
        let result = try #require(await builder.buildProfile(
            albumID: albumID, albumName: "Cyberpunk", userDescription: "Neon city scenes"))

        #expect(result.text == "Neon cityscapes")
        #expect(result.memberCount == 2)
        let user = await captured.lastUser
        #expect(user.contains("neon alley"))
        #expect(user.contains("chrome android"))
        #expect(user.contains("Neon city scenes"))
        #expect(!user.contains("castle on a hill"))
    }

    @Test func returnsNilWithoutPromptBearingMembers() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let albumID = UUID()
        try commitItem(1, prompt: nil, albumIDs: [albumID.uuidString], in: dir)

        let stub = StubClassifier { _, _ in
            Issue.record("classifier must not be called for an album with no prompts")
            return ""
        }
        let builder = AlbumProfileBuilder(itemsDirectory: dir, classifier: stub)
        let result = await builder.buildProfile(albumID: albumID, albumName: "Empty", userDescription: nil)
        #expect(result == nil)
    }

    @Test func returnsNilWhenClassifierFails() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let albumID = UUID()
        try commitItem(1, prompt: "p", albumIDs: [albumID.uuidString], in: dir)

        let stub = StubClassifier { _, _ in throw OpenRouterError.badStatus(500) }
        let builder = AlbumProfileBuilder(itemsDirectory: dir, classifier: stub)
        let result = await builder.buildProfile(albumID: albumID, albumName: "A", userDescription: nil)
        #expect(result == nil)
    }
}

/// Actor-isolated capture box so the @Sendable stub closure can record the
/// messages it received without data races.
private actor CapturedMessages {
    private(set) var lastUser = ""
    func record(system: String, user: String) { lastUser = user }
}
