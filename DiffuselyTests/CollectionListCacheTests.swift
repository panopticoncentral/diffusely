import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite @MainActor struct CollectionListCacheTests {

    private static func stubImage(id: Int) -> CivitaiImage {
        CivitaiImage(id: id, url: "u-\(id)", width: 10, height: 10,
                     nsfwLevel: 1, type: "image", postId: nil, user: nil, stats: nil)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PersistedCollection.self, PersistedAuthor.self,
                 PersistedImage.self, PersistedPost.self, PersistedPostImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    private func apiCollection(
        id: Int, name: String = "C", type: String? = "Image",
        coverId: Int? = 99, coverURL: String? = "abc-def"
    ) -> CivitaiCollection {
        CivitaiCollection(
            id: id, name: name, description: "desc \(id)", type: type,
            imageCount: 7,
            image: CollectionCoverImage(id: coverId, url: coverURL, nsfwLevel: 1,
                                        width: 10, height: 20, hash: "h"),
            user: CivitaiUser(id: 500, username: "owner", image: nil)
        )
    }

    @Test func upsertInsertsNewListCollectionWithMetadata() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())

        _ = svc.upsertUserListCollection(from: apiCollection(id: 1), order: 0, generation: 1)

        let list = svc.getUserListCollections()
        #expect(list.count == 1)
        let row = try #require(list.first)
        #expect(row.id == 1)
        #expect(row.isInUserList == true)
        #expect(row.collectionDescription == "desc 1")
        #expect(row.imageCount == 7)
        #expect(row.listOrder == 0)
        #expect(row.lastSeenListGeneration == 1)
    }

    @Test func toCivitaiCollectionRebuildsCoverImageURL() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let original = apiCollection(id: 2, coverId: 42, coverURL: "uuid-path")

        let row = svc.upsertUserListCollection(from: original, order: 0, generation: 1)
        let rebuilt = row.toCivitaiCollection()

        #expect(rebuilt.image?.fullImageURL == original.image?.fullImageURL)
        #expect(rebuilt.image?.fullImageURL?.contains("uuid-path") == true)
        #expect(rebuilt.type == "Image")
    }

    @Test func upsertDoesNotTouchContentsSyncFields() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())

        // Simulate a collection whose CONTENTS were already synced.
        let existing = svc.getOrCreateCollection(from: apiCollection(id: 3))
        existing.syncCursor = "resume-token"
        existing.lastSyncCompleted = Date(timeIntervalSince1970: 1000)
        existing.syncGeneration = 5
        let img = PersistedImage(from: Self.stubImage(id: 9001))
        img.collection = existing
        existing.images.append(img)

        _ = svc.upsertUserListCollection(from: apiCollection(id: 3, name: "Renamed"),
                                         order: 2, generation: 1)

        let row = try #require(svc.getPersistedCollection(id: 3))
        #expect(row.syncCursor == "resume-token")
        #expect(row.lastSyncCompleted == Date(timeIntervalSince1970: 1000))
        #expect(row.syncGeneration == 5)
        #expect(row.images.count == 1)          // cached contents preserved
        #expect(row.isInUserList == true)
        #expect(row.name == "Renamed")
    }

    @Test func sweepClearsFlagForUnseenRowsButKeepsContents() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())

        // Generation 1: two collections in the list, one with cached contents.
        let gen1 = svc.beginFreshListSyncPass()
        let a = svc.upsertUserListCollection(from: apiCollection(id: 10), order: 0, generation: gen1)
        _ = svc.upsertUserListCollection(from: apiCollection(id: 11), order: 1, generation: gen1)
        let img = PersistedImage(from: Self.stubImage(id: 7777))
        img.collection = a
        a.images.append(img)
        svc.markListSyncCompleted(generation: gen1)

        #expect(svc.getUserListCollections().count == 2)

        // Generation 2: only collection 11 is still in the user's list.
        let gen2 = svc.beginFreshListSyncPass()
        _ = svc.upsertUserListCollection(from: apiCollection(id: 11), order: 0, generation: gen2)
        svc.markListSyncCompleted(generation: gen2)

        let list = svc.getUserListCollections()
        #expect(list.map(\.id) == [11])

        // Collection 10 is gone from the list but its row + contents remain.
        let row10 = try #require(svc.getPersistedCollection(id: 10))
        #expect(row10.isInUserList == false)
        #expect(row10.images.count == 1)        // NOT cascade-deleted
    }

    @Test func getUserListCollectionsReturnsOnlyFlaggedSortedByOrder() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let gen = svc.beginFreshListSyncPass()
        _ = svc.upsertUserListCollection(from: apiCollection(id: 20), order: 2, generation: gen)
        _ = svc.upsertUserListCollection(from: apiCollection(id: 21), order: 0, generation: gen)
        _ = svc.upsertUserListCollection(from: apiCollection(id: 22), order: 1, generation: gen)
        // A row that exists only from a contents sync, never in the list.
        _ = svc.getOrCreateCollection(from: apiCollection(id: 99))

        #expect(svc.getUserListCollections().map(\.id) == [21, 22, 20])
    }

    @Test func listNeedsSyncStateMachine() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())

        // Empty cache → true.
        #expect(svc.listNeedsSync(staleAfter: 300) == true)

        let gen = svc.beginFreshListSyncPass()
        _ = svc.upsertUserListCollection(from: apiCollection(id: 30), order: 0, generation: gen)
        svc.markListSyncCompleted(generation: gen)

        // Just completed → not stale.
        #expect(svc.listNeedsSync(staleAfter: 300) == false)

        // Force staleness.
        let row = try #require(svc.getPersistedCollection(id: 30))
        row.lastListSyncCompleted = Date(timeIntervalSinceNow: -1000)
        #expect(svc.listNeedsSync(staleAfter: 300) == true)

        // Currently syncing → false even if stale.
        svc.markListSyncStarted()
        #expect(svc.listNeedsSync(staleAfter: 300) == false)

        // Interrupt clears the syncing flag so a reopen retries.
        svc.markListSyncInterrupted()
        #expect(svc.listNeedsSync(staleAfter: 300) == true)
    }

    @Test func listSyncIsIndependentOfContentsSync() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())

        // A completed CONTENTS sync must not satisfy list staleness.
        _ = svc.getOrCreateCollection(from: apiCollection(id: 40))
        svc.markSyncCompleted(for: 40)
        #expect(svc.listNeedsSync(staleAfter: 300) == true)

        // A completed LIST sync must not satisfy contents staleness.
        let gen = svc.beginFreshListSyncPass()
        _ = svc.upsertUserListCollection(from: apiCollection(id: 40), order: 0, generation: gen)
        svc.markListSyncCompleted(generation: gen)
        #expect(svc.needsSync(for: 40, staleAfter: 300) == false) // contents synced above, still fresh
        #expect(svc.listNeedsSync(staleAfter: 300) == false)
    }
}
