import Testing
import Foundation
@testable import Diffusely

@MainActor
final class MockFollowingDataSource: FollowingDataSource {
    var followingIds: [Int] = []
    var followingError: Error?
    var users: [Int: CivitaiUser] = [:]   // id -> profile to return
    var failingIds: Set<Int> = []         // ids whose fetch throws
    var deletedIds: Set<Int> = []         // ids whose fetch returns nil
    private(set) var fetchCallCount: [Int: Int] = [:]

    func getFollowingUserIds() async throws -> [Int] {
        if let followingError { throw followingError }
        return followingIds
    }

    func fetchUser(id: Int) async throws -> CivitaiUser? {
        fetchCallCount[id, default: 0] += 1
        if failingIds.contains(id) { throw URLError(.timedOut) }
        if deletedIds.contains(id) { return nil }
        return users[id]
    }
}

@MainActor
final class InMemoryAuthorCache: AuthorCaching {
    var store: [Int: CivitaiUser] = [:]

    func cachedUsers(ids: [Int]) -> [Int: CivitaiUser] {
        var out: [Int: CivitaiUser] = [:]
        for id in ids where store[id] != nil { out[id] = store[id] }
        return out
    }

    func upsert(_ user: CivitaiUser) { store[user.id] = user }
}

@MainActor struct FollowingStoreTests {
    @MainActor private func makeStore(
        _ ds: MockFollowingDataSource,
        _ cache: InMemoryAuthorCache
    ) -> FollowingStore {
        let store = FollowingStore()
        store.configure(dataSource: ds, cache: cache)
        return store
    }

    @MainActor private func makeStore(_ ds: MockFollowingDataSource) -> FollowingStore {
        makeStore(ds, InMemoryAuthorCache())
    }

    @Test func sortsAlphabeticallyCaseInsensitive() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = [3, 1, 2]
        ds.users = [
            3: CivitaiUser(id: 3, username: "Charlie", image: nil),
            1: CivitaiUser(id: 1, username: "alice", image: nil),
            2: CivitaiUser(id: 2, username: "Bob", image: nil)
        ]
        let store = makeStore(ds)
        await store.load()
        #expect(store.rows.map(\.id) == [1, 2, 3])
        #expect(store.state == .loaded)
    }

    @Test func dedupesRepeatedIds() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = [1, 1, 2]
        ds.users = [
            1: CivitaiUser(id: 1, username: "a", image: nil),
            2: CivitaiUser(id: 2, username: "b", image: nil)
        ]
        let store = makeStore(ds)
        await store.load()
        #expect(store.rows.count == 2)
    }

    @Test func cacheHitSkipsNetwork() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = [1]
        let cache = InMemoryAuthorCache()
        cache.store[1] = CivitaiUser(id: 1, username: "alice", image: nil)
        let store = makeStore(ds, cache)
        await store.load()
        #expect(ds.fetchCallCount[1] == nil)
        #expect(store.rows.map(\.id) == [1])
    }

    @Test func gapTriggersExactlyOneFetchAndUpsert() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = [5]
        ds.users = [5: CivitaiUser(id: 5, username: "eve", image: nil)]
        let cache = InMemoryAuthorCache()
        let store = makeStore(ds, cache)
        await store.load()
        #expect(ds.fetchCallCount[5] == 1)
        #expect(cache.store[5]?.username == "eve")
        #expect(store.resolvingCount == 0)
    }

    @Test func failedRowCollatesLast() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = [1, 2]
        ds.users = [1: CivitaiUser(id: 1, username: "alice", image: nil)]
        ds.failingIds = [2]
        let store = makeStore(ds)
        await store.load()
        #expect(store.rows.map(\.id) == [1, 2])
        #expect(store.rows.last?.failed == true)
    }

    @Test func deletedUserHidden() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = [1, 9]
        ds.users = [1: CivitaiUser(id: 1, username: "alice", image: nil)]
        ds.deletedIds = [9]
        let store = makeStore(ds)
        await store.load()
        #expect(store.rows.map(\.id) == [1])
    }

    @Test func noAPIKeyState() async {
        let ds = MockFollowingDataSource()
        ds.followingError = URLError(.userAuthenticationRequired)
        let store = makeStore(ds)
        await store.load()
        #expect(store.state == .noAPIKey)
    }

    @Test func emptyState() async {
        let ds = MockFollowingDataSource()
        ds.followingIds = []
        let store = makeStore(ds)
        await store.load()
        #expect(store.state == .empty)
    }

    @Test func errorState() async {
        let ds = MockFollowingDataSource()
        ds.followingError = URLError(.timedOut)
        let store = makeStore(ds)
        await store.load()
        if case .error = store.state { } else { Issue.record("expected .error, got \(store.state)") }
    }
}
