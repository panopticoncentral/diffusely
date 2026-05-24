import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite @MainActor struct ManageCollectionsViewModelTests {

    // MARK: - Fakes

    /// Fake `ManageCollectionsAPI`. Each saveItem call captures its arguments
    /// and (if `pausesSaveItem` is set) suspends until `releaseAllSaveItems()`
    /// is called, so tests can deterministically interleave a second toggle
    /// while the first is in flight.
    final class FakeAPI: ManageCollectionsAPI {
        var imageCollections: Result<[CivitaiCollection], Error> = .success([])
        var postCollections: Result<[CivitaiCollection], Error> = .success([])
        var membership: Result<[Int], Error> = .success([])
        /// Captured (adding, removing) for each saveItem call, in call order.
        var saveItemCalls: [(adding: [Int], removing: [Int])] = []
        var saveItemResult: Result<Void, Error> = .success(())

        var pausesSaveItem = false
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

        func getUserImageCollections() async throws -> [CivitaiCollection] {
            try imageCollections.get()
        }
        func getUserPostCollections() async throws -> [CivitaiCollection] {
            try postCollections.get()
        }
        func getUserCollectionItemsByItem(target: ManageCollectionsTarget) async throws -> [Int] {
            try membership.get()
        }
        func saveItem(target: ManageCollectionsTarget, adding: [Int], removing: [Int]) async throws {
            saveItemCalls.append((adding, removing))
            if pausesSaveItem {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    pendingContinuations.append(c)
                }
            }
            try saveItemResult.get()
        }

        func releaseAllSaveItems() {
            let conts = pendingContinuations
            pendingContinuations.removeAll()
            pausesSaveItem = false
            for c in conts { c.resume() }
        }
    }

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PersistedCollection.self, PersistedAuthor.self,
                 PersistedImage.self, PersistedPost.self, PersistedPostImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    private func apiCollection(id: Int, name: String) -> CivitaiCollection {
        CivitaiCollection(id: id, name: name, description: nil, type: "Image",
                          imageCount: 0, image: nil,
                          user: CivitaiUser(id: 1, username: "owner", image: nil))
    }

    private func stubImage(id: Int) -> CivitaiImage {
        CivitaiImage(id: id, url: "u-\(id)", width: 1, height: 1,
                     nsfwLevel: 1, type: "image", postId: nil,
                     user: nil, stats: nil)
    }

    private func stubPost(id: Int) -> CivitaiPost {
        CivitaiPost(id: id, nsfwLevel: 1, title: nil, imageCount: 0,
                    user: CivitaiUser(id: 1, username: "a", image: nil),
                    stats: nil, images: [])
    }

    // MARK: - Load

    @Test func loadPopulatesCollectionsAndMembership() async throws {
        let api = FakeAPI()
        api.imageCollections = .success([apiCollection(id: 1, name: "A"), apiCollection(id: 2, name: "B")])
        api.membership = .success([1])
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )

        await vm.load()

        #expect(vm.collections.map(\.id) == [1, 2])
        #expect(vm.membership == [1])
        if case .loaded = vm.loadState {} else { Issue.record("expected .loaded") }
    }

    @Test func loadFailureSetsFailedState() async throws {
        let api = FakeAPI()
        api.membership = .failure(URLError(.timedOut))
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )

        await vm.load()

        if case .failed = vm.loadState {} else { Issue.record("expected .failed") }
    }

    // MARK: - Toggle on

    @Test func toggleOnAddsToMembershipAndCallsSaveItem() async throws {
        let api = FakeAPI()
        let collection = apiCollection(id: 5, name: "Faves")
        api.imageCollections = .success([collection])
        api.membership = .success([])
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        _ = persistence.getOrCreateCollection(from: collection)
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        await vm.toggle(collection)

        #expect(vm.membership.contains(5))
        #expect(api.saveItemCalls.count == 1)
        #expect(api.saveItemCalls[0].adding == [5])
        #expect(api.saveItemCalls[0].removing.isEmpty)
        #expect(persistence.getPersistedCollection(id: 5)?.images.contains { $0.id == 9 } == true)
    }

    @Test func toggleOnUsesPostCollectionsForPostTargetAndWritesPostStub() async throws {
        let api = FakeAPI()
        let collection = CivitaiCollection(id: 50, name: "Post Faves", description: nil, type: "Post",
                                            imageCount: 0, image: nil,
                                            user: CivitaiUser(id: 1, username: "owner", image: nil))
        api.postCollections = .success([collection])
        api.imageCollections = .failure(URLError(.unknown))  // Should NOT be called for a .post target.
        api.membership = .success([])
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        _ = persistence.getOrCreateCollection(from: collection)
        let vm = ManageCollectionsViewModel(
            target: .post(stubPost(id: 30)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        await vm.toggle(collection)

        #expect(vm.membership.contains(50))
        #expect(api.saveItemCalls.count == 1)
        #expect(api.saveItemCalls[0].adding == [50])
        #expect(persistence.getPersistedCollection(id: 50)?.posts.contains { $0.id == 30 } == true)
    }

    // MARK: - Toggle off

    @Test func toggleOffRemovesFromMembershipAndCallsSaveItem() async throws {
        let api = FakeAPI()
        let collection = apiCollection(id: 6, name: "Old")
        api.imageCollections = .success([collection])
        api.membership = .success([6])
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let coll = persistence.getOrCreateCollection(from: collection)
        persistence.addImageStub(stubImage(id: 9), toCollectionId: coll.id)
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        await vm.toggle(collection)

        #expect(!vm.membership.contains(6))
        #expect(api.saveItemCalls[0].adding.isEmpty)
        #expect(api.saveItemCalls[0].removing == [6])
        #expect(persistence.getPersistedCollection(id: 6)?.images.contains { $0.id == 9 } == false)
    }

    // MARK: - Toggle failure reverts

    @Test func toggleFailureRevertsMembershipAndCacheAndRecordsError() async throws {
        let api = FakeAPI()
        let collection = apiCollection(id: 7, name: "X")
        api.imageCollections = .success([collection])
        api.membership = .success([])
        api.saveItemResult = .failure(URLError(.timedOut))
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        _ = persistence.getOrCreateCollection(from: collection)
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        await vm.toggle(collection)

        #expect(!vm.membership.contains(7))           // reverted
        #expect(vm.rowErrors[7] != nil)
        #expect(persistence.getPersistedCollection(id: 7)?.images.isEmpty == true)
        #expect(!vm.pendingFlips.contains(7))
    }

    // MARK: - Rapid double-tap

    @Test func concurrentTogglesDeduplicateBecauseOfPendingFlipsGuard() async throws {
        let api = FakeAPI()
        let collection = apiCollection(id: 8, name: "X")
        api.imageCollections = .success([collection])
        api.membership = .success([])
        api.pausesSaveItem = true
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        _ = persistence.getOrCreateCollection(from: collection)
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        // First tap suspends inside the paused saveItem. Yield until the
        // pendingFlips guard has been set, so the second tap below sees it.
        let firstTap = Task { await vm.toggle(collection) }
        for _ in 0..<10 {
            if vm.pendingFlips.contains(8) { break }
            await Task.yield()
        }
        #expect(vm.pendingFlips.contains(8))
        #expect(api.saveItemCalls.count == 1)

        // Second tap on the same row: dropped by the guard.
        await vm.toggle(collection)
        #expect(api.saveItemCalls.count == 1)

        api.releaseAllSaveItems()
        await firstTap.value
        #expect(!vm.pendingFlips.contains(8))
        #expect(vm.membership.contains(8))            // first tap landed
    }

    // MARK: - addNewCollection

    @Test func addNewCollectionInsertsToListMembershipAndCache() async throws {
        let api = FakeAPI()
        api.imageCollections = .success([])
        api.membership = .success([])
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        let newColl = apiCollection(id: 42, name: "Brand New")
        await vm.addNewCollection(newColl)

        #expect(vm.collections.first?.id == 42)
        #expect(vm.membership.contains(42))
        #expect(api.saveItemCalls.count == 1)
        #expect(api.saveItemCalls[0].adding == [42])
        #expect(persistence.getPersistedCollection(id: 42) != nil)
        #expect(persistence.getPersistedCollection(id: 42)?.images.contains { $0.id == 9 } == true)
    }

    @Test func addNewCollectionFailureKeepsCollectionButNotInMembership() async throws {
        let api = FakeAPI()
        api.imageCollections = .success([])
        api.membership = .success([])
        api.saveItemResult = .failure(URLError(.timedOut))
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let vm = ManageCollectionsViewModel(
            target: .image(stubImage(id: 9)),
            api: api,
            persistence: persistence
        )
        await vm.load()

        let newColl = apiCollection(id: 43, name: "Brand New")
        await vm.addNewCollection(newColl)

        #expect(vm.collections.first?.id == 43)       // stays in list (server-side created)
        #expect(!vm.membership.contains(43))          // but not in membership
        #expect(vm.rowErrors[43] != nil)

        // The PersistedCollection row stays — the collection was really created
        // server-side, even though adding the item to it failed. But the
        // cache stub (the membership row) is reverted.
        #expect(persistence.getPersistedCollection(id: 43) != nil)
        #expect(persistence.getPersistedCollection(id: 43)?.images.contains { $0.id == 9 } == false)
    }
}
