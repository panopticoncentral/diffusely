import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// Test seam: scripted classifier.
final class StubClassifier: PromptClassifying, @unchecked Sendable {
    let handler: @Sendable (String, String) async throws -> String
    init(_ handler: @escaping @Sendable (String, String) async throws -> String) {
        self.handler = handler
    }
    func completeJSON(system: String, user: String) async throws -> String {
        try await handler(system, user)
    }
}

@Suite struct SortAssistantServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
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
    private func makeAlbumService(_ container: ModelContainer, dir: URL) -> LibraryAlbumService {
        LibraryAlbumService(index: LibraryIndexService(modelContainer: container), itemsDirectory: { dir })
    }

    @MainActor
    @Test func freshProfilesGoStraightToReview() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)

        // Album with a FRESH profile (memberCount 5, only 1 actual member).
        let albumID = UUID()
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: albumID, name: "Cyberpunk", createdAt: Date(),
            aiProfile: AlbumAIProfile(text: "Neon cities", builtAt: Date(), memberCount: 5)))
        try commitItem(1, prompt: "member prompt", albumIDs: [albumID.uuidString], in: dir)
        try commitItem(2, prompt: "neon alley", in: dir)       // unsorted candidate
        try commitItem(3, prompt: nil, in: dir)                 // promptless

        let stub = StubClassifier { _, _ in
            #"{"items":[{"id":2,"albums":[{"n":1,"c":0.9}]}]}"#
        }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        #expect(svc.phase == .review)
        #expect(svc.groups.map(\.id) == ["album:\(albumID.uuidString)", "promptless"])
        #expect(svc.groups[0].entries.map(\.itemID) == [2])
        #expect(svc.groups[1].entries.map(\.itemID) == [3])
    }

    @MainActor
    @Test func staleProfileIsBuiltAndConfirmedBeforeClassification() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)

        let albumID = UUID()   // no profile yet → stale
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: albumID, name: "Cyberpunk", createdAt: Date()))
        try commitItem(1, prompt: "member neon prompt", albumIDs: [albumID.uuidString], in: dir)
        try commitItem(2, prompt: "neon alley", in: dir)

        let stub = StubClassifier { system, _ in
            if system.contains("\"profile\"") {
                return #"{"profile":"Neon cityscapes"}"#
            }
            return #"{"items":[{"id":2,"albums":[{"n":1,"c":0.8}]}]}"#
        }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        #expect(svc.phase == .profilesReady)
        #expect(svc.builtProfiles.map(\.text) == ["Neon cityscapes"])

        await svc.confirmProfiles()
        #expect(svc.phase == .review)
        // Profile persisted to the album file with the membership baseline.
        let file = try #require(LibraryAlbumStore(itemsDirectory: dir).read(id: albumID))
        #expect(file.aiProfile?.text == "Neon cityscapes")
        #expect(file.aiProfile?.memberCount == 1)
        #expect(svc.groups.first?.entries.map(\.itemID) == [2])
    }

    @MainActor
    @Test func failedBatchesAreCountedAndOthersSurvive() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)

        let albumID = UUID()
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: albumID, name: "A", createdAt: Date(),
            aiProfile: AlbumAIProfile(text: "a", builtAt: Date(), memberCount: 99)))
        // 26 candidates → 2 batches at classifyBatchSize 25.
        for id in 1...26 { try commitItem(id, prompt: "prompt \(id)", in: dir) }

        let stub = StubClassifier { _, user in
            if user.contains("id 1:") {     // first batch fails
                throw OpenRouterError.badStatus(500)
            }
            return #"{"items":[{"id":26,"albums":[{"n":1,"c":0.9}]}]}"#
        }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        #expect(svc.phase == .review)
        #expect(svc.failedBatchCount == 1)
        #expect(svc.groups.contains { $0.id == "album:\(albumID.uuidString)" })
    }

    @MainActor
    @Test func allBatchesFailingReportsFailure() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: UUID(), name: "A", createdAt: Date(),
            aiProfile: AlbumAIProfile(text: "a", builtAt: Date(), memberCount: 99)))
        try commitItem(1, prompt: "p", in: dir)

        let stub = StubClassifier { _, _ in throw OpenRouterError.badStatus(401) }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        guard case .failed = svc.phase else {
            Issue.record("expected .failed, got \(svc.phase)")
            return
        }
    }

    @MainActor
    @Test func acceptAddsMembershipAndRecordsRejections() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })

        let albumID = await albumService.createAlbum(name: "Cyberpunk")
        try commitItem(1, prompt: "p1", in: dir)
        try commitItem(2, prompt: "p2", in: dir)
        await index.reconcile(itemsDirectory: dir)

        let svc = SortAssistantService(
            albumService: albumService,
            classifier: StubClassifier { _, _ in "" },
            itemsDirectory: dir)
        let group = SortAssistant.ReviewGroup(
            id: "album:\(albumID.uuidString)",
            kind: .album(id: albumID, name: "Cyberpunk"),
            entries: [.init(itemID: 1, confidence: 0.9), .init(itemID: 2, confidence: 0.8)])
        svc.setGroupsForTesting([group])

        await svc.accept(group: group, selectedIDs: [1])   // 2 deselected → rejected

        let writer = LibraryFileWriter(itemsDirectory: dir)
        #expect(writer.readMetadata(itemID: 1)?.albumIDs == [albumID.uuidString])
        #expect(writer.readMetadata(itemID: 2)?.albumIDs == [])
        let state = SortAssistantStateStore(itemsDirectory: dir).read()
        #expect(state.isRejected(itemID: 2, albumID: albumID))
        #expect(!state.isRejected(itemID: 1, albumID: albumID))
    }

    @MainActor
    @Test func acceptNewAlbumCreatesAlbumFirst() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })
        try commitItem(1, prompt: "p1", in: dir)
        try commitItem(2, prompt: "p2", in: dir)
        await index.reconcile(itemsDirectory: dir)

        let svc = SortAssistantService(
            albumService: albumService,
            classifier: StubClassifier { _, _ in "" },
            itemsDirectory: dir)
        let group = SortAssistant.ReviewGroup(
            id: "new:watercolor", kind: .newAlbum(name: "Watercolor"),
            entries: [.init(itemID: 1, confidence: 1), .init(itemID: 2, confidence: 1)])
        svc.setGroupsForTesting([group])

        await svc.accept(group: group, selectedIDs: [1])

        let albums = try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>())
        let created = try #require(albums.first)
        #expect(created.name == "Watercolor")
        let writer = LibraryFileWriter(itemsDirectory: dir)
        #expect(writer.readMetadata(itemID: 1)?.albumIDs == [created.id.uuidString])
        #expect(SortAssistantStateStore(itemsDirectory: dir).read().isNewAlbumRejected(itemID: 2))
    }

    @MainActor
    @Test func acceptForDeletedAlbumIsDropped() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })
        try commitItem(1, prompt: "p1", in: dir)
        await index.reconcile(itemsDirectory: dir)

        let svc = SortAssistantService(
            albumService: albumService,
            classifier: StubClassifier { _, _ in "" },
            itemsDirectory: dir)
        let ghost = UUID()   // album never created / deleted since classify
        let group = SortAssistant.ReviewGroup(
            id: "album:\(ghost.uuidString)", kind: .album(id: ghost, name: "Ghost"),
            entries: [.init(itemID: 1, confidence: 0.9)])
        svc.setGroupsForTesting([group])

        await svc.accept(group: group, selectedIDs: [1])
        #expect(LibraryFileWriter(itemsDirectory: dir).readMetadata(itemID: 1)?.albumIDs == [])
    }

    @MainActor
    @Test func acceptingTheSameGroupTwiceCreatesOneAlbum() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })
        try commitItem(1, prompt: "p1", in: dir)
        await index.reconcile(itemsDirectory: dir)

        let svc = SortAssistantService(
            albumService: albumService,
            classifier: StubClassifier { _, _ in "" },
            itemsDirectory: dir)
        let group = SortAssistant.ReviewGroup(
            id: "new:watercolor", kind: .newAlbum(name: "Watercolor"),
            entries: [.init(itemID: 1, confidence: 1)])
        svc.setGroupsForTesting([group])

        await svc.accept(group: group, selectedIDs: [1])
        await svc.accept(group: group, selectedIDs: [1])   // stale double-tap

        let albums = try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>())
        #expect(albums.count == 1)
    }
}
