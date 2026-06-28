# Users (Following) Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-level "Users" tab that lists the creators you follow (alphabetically), tapping through to their existing content screen.

**Architecture:** A `FollowingStore` (`@MainActor ObservableObject`) fetches the bare follow-ID list from Civitai, resolves each ID to a profile cache-first from `PersistedAuthor` (falling back to a new `user.getById` call with bounded concurrency), and publishes an alphabetically-sorted row list. `FollowingView` renders it and reuses the existing `UserContentView` as the per-creator destination. To keep the iPhone tab bar at 5 visible items, the Settings tab is removed and reached instead from a gear button on the feed header.

**Tech Stack:** SwiftUI, Swift Concurrency, SwiftData (`PersistedAuthor` cache), Civitai tRPC-over-HTTP, Swift Testing (`import Testing`).

Design spec: `docs/superpowers/specs/2026-06-27-users-following-tab-design.md`

---

## File Structure

**New files**
- `Diffusely/Services/Networking/FollowingDataSource.swift` — protocol abstracting the two network calls the feature needs; `CivitaiService` conforms.
- `Diffusely/Services/Following/AuthorCache.swift` — `AuthorCaching` protocol + SwiftData-backed `AuthorCache` (bulk read + upsert of `PersistedAuthor`).
- `Diffusely/Services/Following/FollowingStore.swift` — the `@MainActor` store: load/refresh, cache-first resolution, alphabetical sorting, view state, plus `FollowedUserRow` and `FollowingViewState`.
- `Diffusely/Views/FollowingView.swift` — the tab body (states, list, navigation, settings sheet) + a private `FollowedUserRowView`.
- `DiffuselyTests/CivitaiServiceUserTests.swift` — decode tests for `fetchUser(id:)`.
- `DiffuselyTests/AuthorCacheTests.swift` — in-memory SwiftData tests for the cache.
- `DiffuselyTests/FollowingStoreTests.swift` — store logic tests against mocks.

**Modified files**
- `Diffusely/Services/Networking/CivitaiService.swift` — add `fetchUser(id:)`.
- `Diffusely/ContentView.swift` — iOS: swap the Settings tab for a Users tab; macOS: add a `.users` sidebar section.
- `Diffusely/Views/ImageFeedView.swift` — iOS: add a Settings gear + sheet to the feed header.

**Build/test commands** (Xcode project `Diffusely.xcodeproj`, scheme `Diffusely`):
- iOS build: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' build`
- macOS build: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' build`
- Run one test suite: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/<SuiteName>`

> If `iPhone 17` is not an installed simulator, pick one from `xcrun simctl list devices available | grep iPhone`.

---

## Task 1: `fetchUser(id:)` on CivitaiService + `FollowingDataSource` protocol

**Files:**
- Modify: `Diffusely/Services/Networking/CivitaiService.swift` (add a method near the existing Follow/Unfollow section, ~line 1034)
- Create: `Diffusely/Services/Networking/FollowingDataSource.swift`
- Test: `DiffuselyTests/CivitaiServiceUserTests.swift`

Context: `getFollowingUserIds()` already exists and returns `[Int]` (bare IDs). `user.getById` is a public tRPC procedure returning `{ id, username, image, deletedAt, profilePicture }`. The tRPC success envelope is `[{"result":{"data":{"json": <object> }}}]`. `HTTPStatusError` already exists in `CivitaiService.swift`. Account-scoped calls use `accountBaseURL` (always civitai.com); we use it here too so resolution is paired with the follow-list source.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/CivitaiServiceUserTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

/// Dedicated URLProtocol for this suite so its handler can't race with the
/// stubs other suites install. Mirrors the StubURLProtocol pattern used in
/// CollectionListFetchTests.
final class StubUserByIdURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubUserByIdURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized) @MainActor struct CivitaiServiceUserTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubUserByIdURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func fetchUserDecodesProfile() async throws {
        StubUserByIdURLProtocol.handler = { _ in
            (200, Data(#"[{"result":{"data":{"json":{"id":42,"username":"alice","image":"https://cdn/x.jpg","deletedAt":null}}}}]"#.utf8))
        }
        defer { StubUserByIdURLProtocol.handler = nil }

        let user = try await makeService().fetchUser(id: 42)
        #expect(user?.id == 42)
        #expect(user?.username == "alice")
        #expect(user?.image == "https://cdn/x.jpg")
    }

    @Test func fetchUserReturnsNilForDeleted() async throws {
        StubUserByIdURLProtocol.handler = { _ in
            (200, Data(#"[{"result":{"data":{"json":{"id":7,"username":"ghost","image":null,"deletedAt":"2025-01-01T00:00:00Z"}}}}]"#.utf8))
        }
        defer { StubUserByIdURLProtocol.handler = nil }

        let user = try await makeService().fetchUser(id: 7)
        #expect(user == nil)
    }

    @Test func fetchUserThrowsOnServerError() async {
        StubUserByIdURLProtocol.handler = { _ in (500, Data("boom".utf8)) }
        defer { StubUserByIdURLProtocol.handler = nil }

        await #expect(throws: HTTPStatusError.self) {
            _ = try await self.makeService().fetchUser(id: 1)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/CivitaiServiceUserTests 2>&1 | tail -40`
Expected: COMPILE FAILURE — `value of type 'CivitaiService' has no member 'fetchUser'`.

- [ ] **Step 3: Implement `fetchUser(id:)`**

In `Diffusely/Services/Networking/CivitaiService.swift`, immediately after the `toggleFollowUser(targetUserId:)` method (it ends around line 1034, before the `// MARK: - Paginated Fetch Methods for Sync Service` comment), add:

```swift
    // MARK: - User Lookup

    /// Resolves a single user id to a display profile via `user.getById`.
    /// Returns nil when the user is deleted or the response carries no user
    /// (e.g. a tRPC not-found), so callers can hide them. Throws on transport
    /// errors or non-2xx HTTP status so callers can retry.
    func fetchUser(id: Int) async throws -> CivitaiUser? {
        var components = URLComponents(string: "\(accountBaseURL)/user.getById")!

        let tRPCInput: [String: Any] = [
            "0": ["json": ["id": id]]
        ]
        let inputData = try JSONSerialization.data(withJSONObject: tRPCInput)
        let inputString = String(data: inputData, encoding: .utf8)!

        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString)
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw HTTPStatusError(statusCode: http.statusCode)
        }

        struct UserByIdResponse: Codable { let result: UserByIdResult }
        struct UserByIdResult: Codable { let data: UserByIdData }
        struct UserByIdData: Codable { let json: UserJSON }
        struct UserJSON: Codable {
            let id: Int
            let username: String?
            let image: String?
            let deletedAt: String?
        }

        guard let decoded = try? JSONDecoder().decode([UserByIdResponse].self, from: data),
              let json = decoded.first?.result.data.json else {
            return nil
        }
        if json.deletedAt != nil { return nil }
        return CivitaiUser(id: json.id, username: json.username, image: json.image)
    }
```

- [ ] **Step 4: Create the `FollowingDataSource` protocol + conformance**

Create `Diffusely/Services/Networking/FollowingDataSource.swift`:

```swift
import Foundation

/// The slice of Civitai networking the Following feature depends on. Declaring
/// it as a protocol lets `FollowingStore` be unit-tested against a mock without
/// touching the network.
protocol FollowingDataSource {
    /// IDs of the users the authenticated account follows. Throws
    /// `URLError(.userAuthenticationRequired)` when no API key is configured.
    func getFollowingUserIds() async throws -> [Int]
    /// Resolves a single id to a profile; nil when deleted/unresolvable.
    func fetchUser(id: Int) async throws -> CivitaiUser?
}

extension CivitaiService: FollowingDataSource {}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/CivitaiServiceUserTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` and 3 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Networking/CivitaiService.swift Diffusely/Services/Networking/FollowingDataSource.swift DiffuselyTests/CivitaiServiceUserTests.swift
git commit -m "Add CivitaiService.fetchUser(id:) and FollowingDataSource protocol"
```

---

## Task 2: `AuthorCache` (PersistedAuthor read/upsert)

**Files:**
- Create: `Diffusely/Services/Following/AuthorCache.swift`
- Test: `DiffuselyTests/AuthorCacheTests.swift`

Context: `PersistedAuthor` is a SwiftData `@Model` with `id`, `username`, `imageURL`, plus `init(from: CivitaiUser)` and `toCivitaiUser()`. This mirrors the fetch/upsert pattern already in `CollectionPersistenceService` but exposes a small protocol so the store stays testable.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/AuthorCacheTests.swift`:

```swift
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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/AuthorCacheTests 2>&1 | tail -40`
Expected: COMPILE FAILURE — `cannot find 'AuthorCache' in scope`.

- [ ] **Step 3: Implement `AuthorCaching` + `AuthorCache`**

Create `Diffusely/Services/Following/AuthorCache.swift`:

```swift
import Foundation
import SwiftData

/// Read/write access to the local `PersistedAuthor` profile cache, scoped to
/// what the Following feature needs. A protocol so `FollowingStore` can be
/// tested against an in-memory double.
@MainActor
protocol AuthorCaching {
    /// Returns id→user for every id already cached locally (missing ids omitted).
    func cachedUsers(ids: [Int]) -> [Int: CivitaiUser]
    /// Inserts or updates the cached profile for `user`.
    func upsert(_ user: CivitaiUser)
}

/// SwiftData-backed `AuthorCaching`. Mirrors the author fetch/upsert logic in
/// `CollectionPersistenceService`, reused here so resolved follow profiles warm
/// the same cache the rest of the app reads.
@MainActor
final class AuthorCache: AuthorCaching {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func cachedUsers(ids: [Int]) -> [Int: CivitaiUser] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<PersistedAuthor>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(
            existing.map { ($0.id, $0.toCivitaiUser()) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func upsert(_ user: CivitaiUser) {
        let userId = user.id
        let descriptor = FetchDescriptor<PersistedAuthor>(
            predicate: #Predicate { $0.id == userId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.username = user.username
            existing.imageURL = user.image
        } else {
            modelContext.insert(PersistedAuthor(from: user))
        }
        try? modelContext.save()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/AuthorCacheTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 3 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Following/AuthorCache.swift DiffuselyTests/AuthorCacheTests.swift
git commit -m "Add AuthorCache for PersistedAuthor read/upsert"
```

---

## Task 3: `FollowingStore` (load, resolve, sort, state)

**Files:**
- Create: `Diffusely/Services/Following/FollowingStore.swift`
- Test: `DiffuselyTests/FollowingStoreTests.swift`

Context: This is the core logic. It depends only on `FollowingDataSource` and `AuthorCaching` (both injected), so the tests use mocks — no network, no SwiftData. Resolution runs cache-first; gaps resolve with bounded concurrency (chunks of 6 MainActor tasks); rows stay sorted alphabetically (case-insensitive), with unresolved/failed rows collating last. A `generation` token discards results from a superseded load/refresh.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/FollowingStoreTests.swift`:

```swift
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
    private func makeStore(
        _ ds: MockFollowingDataSource,
        _ cache: InMemoryAuthorCache = InMemoryAuthorCache()
    ) -> FollowingStore {
        let store = FollowingStore()
        store.configure(dataSource: ds, cache: cache)
        return store
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/FollowingStoreTests 2>&1 | tail -40`
Expected: COMPILE FAILURE — `cannot find 'FollowingStore' in scope`.

- [ ] **Step 3: Implement `FollowingStore` (+ `FollowedUserRow`, `FollowingViewState`)**

Create `Diffusely/Services/Following/FollowingStore.swift`:

```swift
import Foundation
import SwiftUI

/// One creator in the Following list. `failed` rows are placeholders for IDs we
/// couldn't resolve this pass; they collate last and retry on refresh.
struct FollowedUserRow: Identifiable, Equatable {
    let id: Int
    let username: String?
    let imageURL: String?
    let failed: Bool

    init(user: CivitaiUser, failed: Bool = false) {
        self.id = user.id
        self.username = user.username
        self.imageURL = user.image
        self.failed = failed
    }

    init(id: Int, username: String?, imageURL: String?, failed: Bool) {
        self.id = id
        self.username = username
        self.imageURL = imageURL
        self.failed = failed
    }

    var civitaiUser: CivitaiUser { CivitaiUser(id: id, username: username, image: imageURL) }

    /// Name used for sorting; nil (collates last) for failed or unnamed rows.
    var sortName: String? {
        guard !failed, let username, !username.isEmpty else { return nil }
        return username
    }

    /// Alphabetical (case-insensitive); unnamed/failed rows last, then by id.
    static func sorted(_ rows: [FollowedUserRow]) -> [FollowedUserRow] {
        rows.sorted { a, b in
            switch (a.sortName, b.sortName) {
            case let (x?, y?):
                let order = x.localizedCaseInsensitiveCompare(y)
                if order == .orderedSame { return a.id < b.id }
                return order == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.id < b.id
            }
        }
    }
}

enum FollowingViewState: Equatable {
    case loading
    case noAPIKey
    case empty
    case error(String)
    case loaded
}

@MainActor
final class FollowingStore: ObservableObject {
    @Published private(set) var rows: [FollowedUserRow] = []
    @Published private(set) var resolvingCount = 0
    @Published private(set) var state: FollowingViewState = .loading

    private var dataSource: FollowingDataSource?
    private var cache: AuthorCaching?
    private var generation = 0

    /// Maximum number of `getById` calls in flight at once.
    private let maxConcurrent = 6

    /// Wires up dependencies once (idempotent). Call before `load()`.
    func configure(dataSource: FollowingDataSource, cache: AuthorCaching) {
        guard self.dataSource == nil else { return }
        self.dataSource = dataSource
        self.cache = cache
    }

    func load() async { await runLoad(isRefresh: false) }
    func refresh() async { await runLoad(isRefresh: true) }

    private func runLoad(isRefresh: Bool) async {
        guard let dataSource, let cache else { return }
        generation &+= 1
        let gen = generation

        if !isRefresh {
            state = .loading
            rows = []
            resolvingCount = 0
        }

        let ids: [Int]
        do {
            ids = try await dataSource.getFollowingUserIds()
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            state = .noAPIKey
            rows = []
            resolvingCount = 0
            return
        } catch {
            if rows.isEmpty { state = .error(error.localizedDescription) }
            resolvingCount = 0
            return
        }
        guard gen == generation else { return }

        var seen = Set<Int>()
        let uniqueIds = ids.filter { seen.insert($0).inserted }

        if uniqueIds.isEmpty {
            rows = []
            resolvingCount = 0
            state = .empty
            return
        }

        // Cache-first: show what we already know, sorted, immediately.
        let cached = cache.cachedUsers(ids: uniqueIds)
        rows = FollowedUserRow.sorted(cached.values.map { FollowedUserRow(user: $0) })
        state = .loaded

        let gaps = uniqueIds.filter { cached[$0] == nil }
        resolvingCount = gaps.count
        await resolveGaps(gaps, generation: gen)
    }

    private func resolveGaps(_ ids: [Int], generation gen: Int) async {
        for chunk in chunked(ids, into: maxConcurrent) {
            if gen != generation { return }
            let tasks = chunk.map { id in
                Task { @MainActor in await self.resolveOne(id: id, generation: gen) }
            }
            for task in tasks { await task.value }
        }
    }

    private func resolveOne(id: Int, generation gen: Int) async {
        guard let dataSource, let cache else { return }
        let resolved: CivitaiUser?
        do {
            resolved = try await dataSource.fetchUser(id: id)
        } catch {
            guard gen == generation else { return }
            applyFailure(id: id)
            resolvingCount = max(0, resolvingCount - 1)
            return
        }
        guard gen == generation else { return }
        if let user = resolved {
            cache.upsert(user)
            apply(user: user)
        }
        resolvingCount = max(0, resolvingCount - 1)
    }

    private func apply(user: CivitaiUser) {
        var updated = rows.filter { $0.id != user.id }
        updated.append(FollowedUserRow(user: user))
        rows = FollowedUserRow.sorted(updated)
    }

    private func applyFailure(id: Int) {
        guard !rows.contains(where: { $0.id == id }) else { return }
        var updated = rows
        updated.append(FollowedUserRow(id: id, username: nil, imageURL: nil, failed: true))
        rows = FollowedUserRow.sorted(updated)
    }

    private func chunked<T>(_ array: [T], into size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return array.isEmpty ? [] : [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0 ..< Swift.min($0 + size, array.count)])
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/FollowingStoreTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 9 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Following/FollowingStore.swift DiffuselyTests/FollowingStoreTests.swift
git commit -m "Add FollowingStore with cache-first resolution and alphabetical sort"
```

---

## Task 4: `FollowingView` (the tab body)

**Files:**
- Create: `Diffusely/Views/FollowingView.swift`

Context: Renders `FollowingStore` state. Reuses the avatar+username row look from `AuthorSectionHeader` and the existing per-platform navigation to `UserContentView` (iOS `fullScreenCover(item:)`, macOS `feedNavigator.push`). The no-API-key prompt presents `SettingsView` in its own sheet so it works on both platforms. `Color(.systemBackground)`/`.secondarySystemBackground` are cross-platform via `PlatformImage.swift`. This view is SwiftUI, so verification is build + the existing store tests (no new unit test).

- [ ] **Step 1: Create `FollowingView.swift`**

```swift
import SwiftUI

struct FollowingView: View {
    @StateObject private var civitaiService = CivitaiService()
    @StateObject private var store = FollowingStore()
    @Environment(\.modelContext) private var modelContext

    @State private var showingSettings = false
    #if os(iOS)
    @State private var selectedUser: CivitaiUser?
    #endif
    #if os(macOS)
    @EnvironmentObject private var feedNavigator: FeedNavigator
    #endif

    var body: some View {
        content
            .navigationTitle("Users")
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #if os(iOS)
            .fullScreenCover(item: $selectedUser) { user in
                UserContentView(user: user)
            }
            #endif
            .task {
                store.configure(
                    dataSource: civitaiService,
                    cache: AuthorCache(modelContext: modelContext)
                )
                await store.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noAPIKey:
            messageView(
                systemImage: "person.crop.circle.badge.questionmark",
                title: "Sign in to see who you follow",
                message: "Add your Civitai API key to load the creators you follow.",
                actionTitle: "Open Settings"
            ) { showingSettings = true }
        case .empty:
            messageView(
                systemImage: "person.2",
                title: "You're not following anyone yet",
                message: "Creators you follow on Civitai will appear here.",
                actionTitle: nil,
                action: nil
            )
        case .error(let description):
            messageView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load your follows",
                message: description,
                actionTitle: "Retry"
            ) { Task { await store.refresh() } }
        case .loaded:
            listView
        }
    }

    private var listView: some View {
        List {
            ForEach(store.rows) { row in
                Button {
                    open(row.civitaiUser)
                } label: {
                    FollowedUserRowView(user: row.civitaiUser, failed: row.failed)
                }
                .buttonStyle(.plain)
            }

            if store.resolvingCount > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Resolving \(store.resolvingCount) more…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private func messageView(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ user: CivitaiUser) {
        #if os(macOS)
        feedNavigator.push(user)
        #else
        selectedUser = user
        #endif
    }
}

/// One row: circular avatar + username, mirroring `AuthorSectionHeader`.
private struct FollowedUserRowView: View {
    let user: CivitaiUser
    let failed: Bool

    var body: some View {
        HStack(spacing: 12) {
            avatar
            Text(user.username ?? (failed ? "Unavailable" : "Unknown Artist"))
                .font(.headline)
                .foregroundColor(failed ? .secondary : .primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let imageURL = user.image, let url = URL(string: imageURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    ProgressView().frame(width: 40, height: 40)
                default:
                    placeholderAvatar
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            placeholderAvatar
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 40, height: 40)
            .overlay(Image(systemName: "person.fill").foregroundColor(.gray))
    }
}
```

- [ ] **Step 2: Verify it builds (iOS)**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. (The view isn't reachable from any tab yet — Task 5 wires it in.)

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/FollowingView.swift
git commit -m "Add FollowingView listing followed creators"
```

---

## Task 5: Wire the Users tab into `ContentView` (and drop the Settings tab)

**Files:**
- Modify: `Diffusely/ContentView.swift`

Context: iOS uses a `TabView` (tags 0–4, Settings currently tag 4); macOS uses a `NavigationSplitView` driven by the `SidebarSection` enum. We replace the iOS Settings tab with a Users tab, and add a `.users` macOS sidebar section. macOS Settings already lives in the app menu, so it's unaffected there. (The iOS Settings entry point is added in Task 6.)

- [ ] **Step 1: Add the macOS `.users` sidebar section**

In `Diffusely/ContentView.swift`, in the `SidebarSection` enum (inside the `#if os(macOS)` block), add the `users` case and its icon:

Change:
```swift
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case images = "Images"
    case videos = "Videos"
    case collections = "Collections"
    case library = "Library"

    var id: Self { self }

    var icon: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .videos: "video"
        case .collections: "square.stack.3d.up"
        case .library: "externaldrive.badge.icloud"
        }
    }
}
```
to:
```swift
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case images = "Images"
    case videos = "Videos"
    case collections = "Collections"
    case library = "Library"
    case users = "Users"

    var id: Self { self }

    var icon: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .videos: "video"
        case .collections: "square.stack.3d.up"
        case .library: "externaldrive.badge.icloud"
        case .users: "person.2"
        }
    }
}
```

- [ ] **Step 2: Render `FollowingView` for the macOS `.users` section**

In the macOS `switch selectedSection ?? .images` block, add a case after `.library`:

Change:
```swift
                    case .library:
                        LibraryView()
                    }
```
to:
```swift
                    case .library:
                        LibraryView()
                    case .users:
                        FollowingView()
                    }
```

- [ ] **Step 3: Replace the iOS Settings tab with the Users tab**

In the `#else` (iOS) `TabView`, replace the `SettingsView()` tab block:

Change:
```swift
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(4)
```
to:
```swift
            NavigationStack {
                FollowingView()
            }
                .tabItem {
                    Image(systemName: "person.2")
                    Text("Users")
                }
                .tag(4)
```

- [ ] **Step 4: Verify it builds on both platforms**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/ContentView.swift
git commit -m "Add Users tab; remove Settings from the iOS tab bar"
```

---

## Task 6: Settings gear on the iOS feed header

**Files:**
- Modify: `Diffusely/Views/ImageFeedView.swift`

Context: With Settings off the iPhone tab bar, it's reached from a gear in the feed header — the iOS-only custom `HStack` at the top of `ImageFeedView` (the `#else` branch of `body`, ~lines 69–88). macOS is unchanged (Settings stays in the app menu). `SettingsView()` wraps itself in a `NavigationStack` on iOS and inherits the `libraryStore` environment object from `ContentView`, so presenting it as a sheet just works.

- [ ] **Step 1: Add iOS-only settings state**

In `Diffusely/Views/ImageFeedView.swift`, after the `@State private var hasLoadedOnce = false` line, add:

```swift
    #if os(iOS)
    @State private var showingSettings = false
    #endif
```

- [ ] **Step 2: Add the gear button and sheet to the iOS header**

In the `#else` branch of `body`, change:
```swift
        VStack(spacing: 0) {
            HStack {
                Text(videos ? "Videos" : "Images")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                Spacer()

                FeedFilterMenu(
                    selectedPeriod: $selectedPeriod,
                    selectedSort: $selectedSort
                )
            }
            .background(Color(.systemBackground))

            feedScroll
        }
```
to:
```swift
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(videos ? "Videos" : "Images")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .padding(.leading, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                Spacer()

                FeedFilterMenu(
                    selectedPeriod: $selectedPeriod,
                    selectedSort: $selectedSort
                )

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                        .font(.title3)
                }
                .padding(.trailing, 20)
            }
            .background(Color(.systemBackground))

            feedScroll
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
```

- [ ] **Step 3: Verify it builds on both platforms**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **` (macOS path unchanged — the gear is iOS-only).

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/ImageFeedView.swift
git commit -m "Add Settings gear to the iOS feed header"
```

---

## Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite (iOS)**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, including `CivitaiServiceUserTests`, `AuthorCacheTests`, `FollowingStoreTests`, and no regressions in existing suites.

- [ ] **Step 2: Confirm the macOS build**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke check (with an API key configured)**

Launch the app (`/run` skill or Xcode) and verify:
- iOS: a **Users** tab (person.2 icon) appears; Settings is reachable via the gear on the Images/Videos header.
- The Users tab shows followed creators alphabetically, avatars/names fill in, and a "Resolving N more…" row shows while gaps resolve on first load.
- Tapping a creator opens their existing content screen; its Follow/Following button still works.
- With no API key: the Users tab shows the sign-in prompt; "Open Settings" presents Settings.
- macOS: a **Users** sidebar item appears and behaves the same; Settings remains in the app menu.

- [ ] **Step 4: Final commit (if any uncommitted verification tweaks)**

```bash
git status   # expect clean; commit only if a fix was needed during verification
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** tab placement (Task 5), Settings relocation/gear (Tasks 5–6), alphabetical sort (Task 3 `FollowedUserRow.sorted`), cache-first + bounded-concurrency resolution (Task 3), `user.getById` resolution (Task 1), `PersistedAuthor` reuse (Task 2), states incl. no-API-key/empty/error (Tasks 3–4), pull-to-refresh (Task 4), deleted-user hiding (Tasks 1+3), both-platform builds (Tasks 5–7). The unfollow-from-list, alternate sorts, search, and grid are intentionally out of scope per the spec.
- **Type consistency:** `FollowingDataSource.fetchUser(id:) -> CivitaiUser?`, `AuthorCaching.cachedUsers(ids:)`/`upsert(_:)`, `FollowingStore.configure/load/refresh`, `FollowedUserRow`, and `FollowingViewState` names are used identically across Tasks 1–6.
- **Concurrency note:** gap resolution uses chunks of `Task { @MainActor in … }` so nothing non-Sendable crosses an actor boundary — the same MainActor→nonisolated async call shape the app already uses when views call `CivitaiService`.
