import Testing
import Foundation
import SwiftData
@testable import Diffusely

@MainActor
@Suite struct LibraryAlbumFilterTests {
    private func make(_ id: Int, albums: [String], pub: TimeInterval) -> PersistedLibraryItem {
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: "alice", avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: Date(timeIntervalSince1970: pub),
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t")
        return PersistedLibraryItem(metadata: meta, downloadStatus: .downloaded)
    }

    private func makeContext(items: [PersistedLibraryItem], albums: [PersistedAlbum]) throws -> ModelContext {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let ctx = ModelContext(container)
        items.forEach { ctx.insert($0) }
        albums.forEach { ctx.insert($0) }
        try ctx.save()
        return ctx
    }

    @Test func albumFilterReturnsOnlyMembers() throws {
        let a = UUID()
        let ctx = try makeContext(
            items: [make(1, albums: [a.uuidString], pub: 1), make(2, albums: [], pub: 2)],
            albums: [PersistedAlbum(id: a, name: "A", createdAt: Date())])
        let svc = LibrarySortService(modelContext: ctx)
        let content = svc.sortedLibraryContent(sort: .dateNewest, filter: .album(a))
        guard case .flat(let items) = content else { Issue.record("expected flat"); return }
        #expect(items.map(\.itemID) == [1])
    }

    @Test func notInAnyAlbumIsComplement() throws {
        let a = UUID()
        let ctx = try makeContext(
            items: [make(1, albums: [a.uuidString], pub: 1), make(2, albums: [], pub: 2)],
            albums: [PersistedAlbum(id: a, name: "A", createdAt: Date())])
        let svc = LibrarySortService(modelContext: ctx)
        let content = svc.sortedLibraryContent(sort: .dateNewest, filter: .notInAnyAlbum)
        guard case .flat(let items) = content else { Issue.record("expected flat"); return }
        #expect(items.map(\.itemID) == [2])
    }

    @Test func danglingMembershipCountsAsNotInAnyAlbum() throws {
        // Item references an album UUID with no PersistedAlbum row (deleted elsewhere).
        let ctx = try makeContext(
            items: [make(1, albums: [UUID().uuidString], pub: 1)],
            albums: [])
        let svc = LibrarySortService(modelContext: ctx)
        let content = svc.sortedLibraryContent(sort: .dateNewest, filter: .notInAnyAlbum)
        guard case .flat(let items) = content else { Issue.record("expected flat"); return }
        #expect(items.map(\.itemID) == [1])
    }

    @Test func albumSummariesReportCountAndCover() throws {
        let a = UUID()
        let ctx = try makeContext(
            items: [make(1, albums: [a.uuidString], pub: 1), make(2, albums: [a.uuidString], pub: 9)],
            albums: [PersistedAlbum(id: a, name: "A", createdAt: Date())])
        let svc = LibrarySortService(modelContext: ctx)
        let summaries = svc.albumSummaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.count == 2)
        #expect(summaries.first?.coverItem?.itemID == 2)   // most recent member
    }
}
