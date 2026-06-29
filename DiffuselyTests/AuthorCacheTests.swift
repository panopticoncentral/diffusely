import Testing
import Foundation
import SwiftData
@testable import Diffusely

@MainActor struct AuthorCacheTests {
    private func makeContext() throws -> ModelContext {
        // Same model set the app registers, kept in memory for the test.
        let schema = Schema([
            PersistedCollection.self,
            PersistedAuthor.self,
            PersistedImage.self,
            PersistedPost.self,
            PersistedPostImage.self,
            PersistedLibraryItem.self,
            PersistedAlbum.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    @Test func upsertInsertsThenCachedUsersReturnsIt() throws {
        let cache = AuthorCache(modelContext: try makeContext())
        cache.upsert(CivitaiUser(id: 1, username: "alice", image: "a.jpg"))

        let found = cache.cachedUsers(ids: [1, 2])
        #expect(found.count == 1)
        #expect(found[1]?.username == "alice")
        #expect(found[2] == nil)
    }

    @Test func upsertUpdatesExisting() throws {
        let cache = AuthorCache(modelContext: try makeContext())
        cache.upsert(CivitaiUser(id: 1, username: "old", image: nil))
        cache.upsert(CivitaiUser(id: 1, username: "new", image: "n.jpg"))

        let found = cache.cachedUsers(ids: [1])
        #expect(found[1]?.username == "new")
        #expect(found[1]?.image == "n.jpg")
    }

    @Test func cachedUsersEmptyForEmptyInput() throws {
        let cache = AuthorCache(modelContext: try makeContext())
        #expect(cache.cachedUsers(ids: []).isEmpty)
    }
}
