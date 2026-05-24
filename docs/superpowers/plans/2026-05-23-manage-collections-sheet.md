# Manage Collections Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the one-shot "Add to Collection" picker (and the in-collection per-item remove confirmation) with a single NYT-Cooking-style "Manage Collections" sheet — a list of the user's collections with a toggle per row, showing live membership and flipping add/remove in real time via the Civitai API.

**Architecture:** A new `ManageCollectionsSheet` view backed by a `ManageCollectionsViewModel` that fetches authoritative membership from `collection.getUserCollectionItemsByItem` and writes via the batched `collection.saveItem`. Each toggle is optimistic, writes through to the local SwiftData cache, and reverts on failure. Six existing entry points swap their old picker for the new sheet; `CollectionDetailView`'s remove confirmation flow is deleted in favor of the sheet.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test` macros). The project uses Xcode's `fileSystemSynchronizedGroups` — new `.swift` files under `Diffusely/` or `DiffuselyTests/` are auto-included; no `project.pbxproj` edits required.

**Standard commands** (a simulator from `xcrun simctl list devices available`; examples use `iPhone 17 Pro`):

- Build: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
- Run a single test class: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/<ClassName> 2>&1 | tail -30`

**Spec:** [2026-05-23-manage-collections-sheet-design.md](../specs/2026-05-23-manage-collections-sheet-design.md)

---

## File Map

**Create:**
- `Diffusely/Models/ManageCollectionsTarget.swift` — value type identifying the target item.
- `Diffusely/Services/ManageCollectionsAPI.swift` — protocol for the VM's API dependency.
- `Diffusely/Services/ManageCollectionsViewModel.swift` — `@MainActor` `ObservableObject` driving the sheet.
- `Diffusely/Views/ManageCollectionsSheet.swift` — the SwiftUI view.
- `DiffuselyTests/CivitaiServiceManageCollectionsTests.swift` — request-shape tests for the two new/changed service methods.
- `DiffuselyTests/ManageCollectionsViewModelTests.swift` — VM logic tests with a fake `ManageCollectionsAPI`.

**Modify:**
- `Diffusely/Services/CivitaiService.swift` — add `getUserCollectionItemsByItem`, `saveItem`; conform to `ManageCollectionsAPI`; delete four old add/remove methods (Task 14).
- `Diffusely/Services/CollectionPersistenceService.swift` — add `addImageStub`, `addPostStub`.
- `Diffusely/Views/ImageDetailView.swift` — swap picker for sheet (Task 8).
- `Diffusely/Views/PostDetailView.swift` — swap picker for sheet (Task 9).
- `Diffusely/Views/ImageFeedItemView.swift` — swap picker for sheet (Task 10).
- `Diffusely/Views/PostsFeedItemView.swift` — swap picker for sheet (Task 11).
- `Diffusely/Views/AuthorContentGrid.swift` — swap `PostThumbnailView`'s picker for sheet (Task 12); drop `onRequestRemove` plumbing (Task 13).
- `Diffusely/Views/CollectionDetailView.swift` — replace remove confirmation with the new sheet; drop `pendingRemoval` state and `performRemoval` (Task 13).
- `DiffuselyTests/MultiCollectionMembershipTests.swift` — add stub-method tests (Task 2).

**Delete:**
- `Diffusely/Views/CollectionPickerView.swift` (Task 14).

---

## Task 1: Add `ManageCollectionsTarget` model

**Files:**
- Create: `Diffusely/Models/ManageCollectionsTarget.swift`

The target carries the *full* `CivitaiImage` / `CivitaiPost` (not just the id) so the cache write-through can materialize a `Persisted*` row from it. Every call site already has the full model in scope.

- [ ] **Step 1: Create the file**

```swift
// Diffusely/Models/ManageCollectionsTarget.swift
import Foundation

/// Identifies the item whose collection membership is being managed.
/// Carries the full `CivitaiImage` / `CivitaiPost` (not just an id) because the
/// optimistic cache write-through needs to materialize a `Persisted*` row.
enum ManageCollectionsTarget: Hashable {
    case image(CivitaiImage)
    case post(CivitaiPost)

    /// "image" / "post" — used in user-facing copy.
    var displayName: String {
        switch self {
        case .image: return "image"
        case .post: return "post"
        }
    }

    /// The numeric id of the underlying item.
    var itemId: Int {
        switch self {
        case .image(let image): return image.id
        case .post(let post): return post.id
        }
    }

    /// Matches Civitai's `CollectionType` enum: "Image" or "Post".
    /// Used to filter the user's collections shown in the sheet.
    var collectionType: String {
        switch self {
        case .image: return "Image"
        case .post: return "Post"
        }
    }
}
```

- [ ] **Step 2: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Models/ManageCollectionsTarget.swift
git commit -m "Add ManageCollectionsTarget model"
```

---

## Task 2: Add cache write-through to `CollectionPersistenceService`

**Files:**
- Modify: `Diffusely/Services/CollectionPersistenceService.swift`
- Test: `DiffuselyTests/MultiCollectionMembershipTests.swift`

`addImageStub` / `addPostStub` insert a `PersistedImage` / `PersistedPost` row tied to a collection (and child `PersistedPostImage` rows for posts), stamped with the destination collection's current `syncGeneration` so a concurrent mark-and-sweep sync won't evict them. They are idempotent: if a row for the item already exists in the collection, no new row is inserted and no error is thrown.

- [ ] **Step 1: Add the failing tests**

Open `DiffuselyTests/MultiCollectionMembershipTests.swift` and append the following three `@Test` cases inside the `MultiCollectionMembershipTests` suite, just before the closing brace on the last line:

```swift
    // MARK: - Optimistic add-stub tests (used by ManageCollectionsSheet)

    @Test func addImageStubInsertsRowStampedWithCollectionGeneration() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let coll = svc.getOrCreateCollection(from: apiCollection(id: 11, type: "Image"))
        coll.syncGeneration = 7  // Simulate a collection that has been synced before.

        svc.addImageStub(stubImage(id: 100), toCollectionId: coll.id)

        #expect(coll.images.count == 1)
        #expect(coll.images.first?.id == 100)
        #expect(coll.images.first?.lastSeenGeneration == 7)
    }

    @Test func addImageStubIsIdempotent() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let coll = svc.getOrCreateCollection(from: apiCollection(id: 12, type: "Image"))
        let image = stubImage(id: 101)

        svc.addImageStub(image, toCollectionId: coll.id)
        svc.addImageStub(image, toCollectionId: coll.id)

        #expect(coll.images.filter { $0.id == 101 }.count == 1)
    }

    @Test func addPostStubMaterializesChildImages() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let coll = svc.getOrCreateCollection(from: apiCollection(id: 13, type: "Post"))
        coll.syncGeneration = 3

        svc.addPostStub(stubPost(id: 200, imageId: 201), toCollectionId: coll.id)

        let inserted = coll.posts.first { $0.id == 200 }
        #expect(inserted != nil)
        #expect(inserted?.lastSeenGeneration == 3)
        #expect(inserted?.images.count == 1)
        #expect(inserted?.images.first?.id == 201)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/MultiCollectionMembershipTests 2>&1 | tail -30`
Expected: build error — `addImageStub` / `addPostStub` not defined.

- [ ] **Step 3: Implement the stub methods**

Open `Diffusely/Services/CollectionPersistenceService.swift`. Find the `// MARK: - Removal` block (around line 132). Immediately above it, insert this new MARK block:

```swift
    // MARK: - Optimistic Stubs (write-through for ManageCollectionsSheet)

    /// Inserts a `PersistedImage` row tying `image` to the collection if one
    /// does not already exist. Stamps it with the collection's current
    /// `syncGeneration` so a concurrent mark-and-sweep won't evict it.
    /// Idempotent: a second call for the same (imageId, collectionId) is a no-op.
    func addImageStub(_ image: CivitaiImage, toCollectionId collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        let imageId = image.id
        let descriptor = FetchDescriptor<PersistedImage>(
            predicate: #Predicate { $0.id == imageId && $0.collection?.id == collectionId }
        )
        if (try? modelContext.fetch(descriptor).first) != nil { return }

        let persisted = PersistedImage(from: image)
        persisted.collection = collection
        persisted.lastSeenGeneration = collection.syncGeneration
        if let user = image.user {
            persisted.author = getOrCreateAuthor(from: user)
        }
        modelContext.insert(persisted)
        collection.images.append(persisted)
        try? modelContext.save()
    }

    /// Inserts a `PersistedPost` row (plus child `PersistedPostImage` rows
    /// from `post.safeImages`) tying `post` to the collection if one does not
    /// already exist. Stamps with current `syncGeneration`. Idempotent.
    func addPostStub(_ post: CivitaiPost, toCollectionId collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        let postId = post.id
        let descriptor = FetchDescriptor<PersistedPost>(
            predicate: #Predicate { $0.id == postId && $0.collection?.id == collectionId }
        )
        if (try? modelContext.fetch(descriptor).first) != nil { return }

        let persisted = PersistedPost(from: post)
        persisted.collection = collection
        persisted.lastSeenGeneration = collection.syncGeneration
        persisted.author = getOrCreateAuthor(from: post.user)

        for image in post.safeImages {
            let postImage = PersistedPostImage(from: image)
            postImage.post = persisted
            modelContext.insert(postImage)
            persisted.images.append(postImage)
        }

        modelContext.insert(persisted)
        collection.posts.append(persisted)
        try? modelContext.save()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/MultiCollectionMembershipTests 2>&1 | tail -30`
Expected: all `MultiCollectionMembershipTests` pass (existing three + three new = six).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/CollectionPersistenceService.swift DiffuselyTests/MultiCollectionMembershipTests.swift
git commit -m "Add optimistic addImageStub/addPostStub to CollectionPersistenceService"
```

---

## Task 3: Add `getUserCollectionItemsByItem` to `CivitaiService`

**Files:**
- Modify: `Diffusely/Services/CivitaiService.swift`
- Create: `DiffuselyTests/CivitaiServiceManageCollectionsTests.swift`

Wraps the tRPC POST to `collection.getUserCollectionItemsByItem` and decodes the response to `[Int]` (collection IDs). Sends `imageId` or `postId` (per target), `type` matching the collection type, and `contributingOnly: true` so the result lines up with what `getUserImageCollections` / `getUserPostCollections` returns.

- [ ] **Step 1: Create the failing test file**

```swift
// DiffuselyTests/CivitaiServiceManageCollectionsTests.swift
import Testing
import Foundation
@testable import Diffusely

@Suite(.serialized) @MainActor struct CivitaiServiceManageCollectionsTests {

    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
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

    /// Extracts the JSON dictionary tRPC encodes as `?input={"0":{"json":{…}}}`.
    private func tRPCInput(from request: URLRequest) -> [String: Any]? {
        guard let url = request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let inputStr = comps.queryItems?.first(where: { $0.name == "input" })?.value,
              let data = inputStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zero = obj["0"] as? [String: Any],
              let json = zero["json"] as? [String: Any] else { return nil }
        return json
    }

    /// Decodes the POST body tRPC encodes as `{"0":{"json":{…}}}`.
    private func tRPCBody(from request: URLRequest) -> [String: Any]? {
        // URLSession strips httpBody when sending via URLProtocol; the body is
        // available on `httpBodyStream` instead.
        let stream: InputStream
        if let s = request.httpBodyStream {
            stream = s
        } else if let data = request.httpBody {
            return decode(data)
        } else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return decode(data)
    }

    private func decode(_ data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zero = obj["0"] as? [String: Any],
              let json = zero["json"] as? [String: Any] else { return nil }
        return json
    }

    @Test func getUserCollectionItemsByItemSendsImageIdAndDecodesIds() async throws {
        let service = makeService()
        var capturedInput: [String: Any]?
        StubURLProtocol.handler = { request in
            capturedInput = self.tRPCInput(from: request)
            let json = """
            [{"result":{"data":{"json":[
                {"collectionId":10,"addedById":1,"tagId":null,"collection":{"userId":1,"read":"Private"},"canRemoveItem":true},
                {"collectionId":20,"addedById":1,"tagId":null,"collection":{"userId":1,"read":"Private"},"canRemoveItem":true}
            ]}}}]
            """
            return (200, Data(json.utf8))
        }

        let ids = try await service.getUserCollectionItemsByItem(target: .image(stubImage(id: 99)))

        #expect(ids == [10, 20])
        #expect(capturedInput?["imageId"] as? Int == 99)
        #expect(capturedInput?["type"] as? String == "Image")
        #expect(capturedInput?["contributingOnly"] as? Bool == true)
        StubURLProtocol.handler = nil
    }

    @Test func getUserCollectionItemsByItemSendsPostIdForPostTarget() async throws {
        let service = makeService()
        var capturedInput: [String: Any]?
        StubURLProtocol.handler = { request in
            capturedInput = self.tRPCInput(from: request)
            return (200, Data("[{\"result\":{\"data\":{\"json\":[]}}}]".utf8))
        }

        _ = try await service.getUserCollectionItemsByItem(target: .post(stubPost(id: 77)))

        #expect(capturedInput?["postId"] as? Int == 77)
        #expect(capturedInput?["type"] as? String == "Post")
        StubURLProtocol.handler = nil
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/CivitaiServiceManageCollectionsTests 2>&1 | tail -30`
Expected: build error — `getUserCollectionItemsByItem` not defined.

- [ ] **Step 3: Implement the method**

Open `Diffusely/Services/CivitaiService.swift`. Find the existing `func getUserImageCollections()` (around line 816). Immediately above it, insert this new method:

```swift
    /// Returns the collection ids that contain the given image or post,
    /// filtered to collections the authenticated user can write to.
    /// Source of truth for the "Manage Collections" sheet's membership state.
    func getUserCollectionItemsByItem(target: ManageCollectionsTarget) async throws -> [Int] {
        var components = URLComponents(string: "\(baseURL)/collection.getUserCollectionItemsByItem")!

        var inputParams: [String: Any] = [
            "type": target.collectionType,
            "contributingOnly": true
        ]
        switch target {
        case .image(let image): inputParams["imageId"] = image.id
        case .post(let post):   inputParams["postId"] = post.id
        }

        let tRPCInput = ["0": ["json": inputParams]]
        let inputData = try JSONSerialization.data(withJSONObject: tRPCInput)
        let inputString = String(data: inputData, encoding: .utf8)!

        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString)
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        struct Envelope: Decodable {
            let result: ResultBox
            struct ResultBox: Decodable { let data: DataBox }
            struct DataBox: Decodable { let json: [Item] }
            struct Item: Decodable { let collectionId: Int }
        }
        let decoded = try JSONDecoder().decode([Envelope].self, from: data)
        return decoded[0].result.data.json.map(\.collectionId)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/CivitaiServiceManageCollectionsTests 2>&1 | tail -30`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/CivitaiService.swift DiffuselyTests/CivitaiServiceManageCollectionsTests.swift
git commit -m "Add CivitaiService.getUserCollectionItemsByItem"
```

---

## Task 4: Add unified `saveItem` to `CivitaiService`

**Files:**
- Modify: `Diffusely/Services/CivitaiService.swift`
- Modify: `DiffuselyTests/CivitaiServiceManageCollectionsTests.swift`

A single method that batches add and remove in one `collection.saveItem` request. The four existing single-direction methods (`addImageToCollection`, `removeImageFromCollection`, `addPostToCollection`, `removePostFromCollection`) stay in place for now — they will be deleted in Task 14 once all callers migrate.

- [ ] **Step 1: Add failing tests**

Open `DiffuselyTests/CivitaiServiceManageCollectionsTests.swift`. Append these test cases inside the suite, before the closing brace:

```swift
    @Test func saveItemSendsCombinedAddAndRemoveLists() async throws {
        let service = makeService()
        var capturedBody: [String: Any]?
        StubURLProtocol.handler = { request in
            capturedBody = self.tRPCBody(from: request)
            return (200, Data("[{\"result\":{\"data\":{\"json\":{\"status\":\"updated\"}}}}]".utf8))
        }

        try await service.saveItem(
            target: .image(stubImage(id: 50)),
            adding: [101, 102],
            removing: [200]
        )

        #expect(capturedBody?["imageId"] as? Int == 50)
        #expect(capturedBody?["type"] as? String == "Image")
        let collections = capturedBody?["collections"] as? [[String: Any]]
        #expect(collections?.count == 2)
        #expect(collections?.compactMap { $0["collectionId"] as? Int }.sorted() == [101, 102])
        #expect((capturedBody?["removeFromCollectionIds"] as? [Int])?.sorted() == [200])
        StubURLProtocol.handler = nil
    }

    @Test func saveItemSendsPostIdForPostTarget() async throws {
        let service = makeService()
        var capturedBody: [String: Any]?
        StubURLProtocol.handler = { request in
            capturedBody = self.tRPCBody(from: request)
            return (200, Data("[{\"result\":{\"data\":{\"json\":{\"status\":\"added\"}}}}]".utf8))
        }

        try await service.saveItem(
            target: .post(stubPost(id: 33)),
            adding: [42],
            removing: []
        )

        #expect(capturedBody?["postId"] as? Int == 33)
        #expect(capturedBody?["type"] as? String == "Post")
        #expect((capturedBody?["removeFromCollectionIds"] as? [Int])?.isEmpty == true)
        StubURLProtocol.handler = nil
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/CivitaiServiceManageCollectionsTests 2>&1 | tail -30`
Expected: build error — `saveItem` not defined.

- [ ] **Step 3: Implement the method**

Open `Diffusely/Services/CivitaiService.swift`. Find the existing `func addImageToCollection` (around line 711). Immediately above it, insert this new method:

```swift
    /// Adds the target item to `adding` collections and removes it from
    /// `removing` collections in a single `collection.saveItem` request.
    /// Either array may be empty; both arrays empty is a no-op but still sends
    /// the request (caller should avoid this).
    func saveItem(
        target: ManageCollectionsTarget,
        adding: [Int],
        removing: [Int]
    ) async throws {
        let url = URL(string: "\(baseURL)/collection.saveItem?batch=1")!

        var inputParams: [String: Any] = [
            "type": target.collectionType,
            "collections": adding.map { ["collectionId": $0] },
            "removeFromCollectionIds": removing
        ]
        switch target {
        case .image(let image): inputParams["imageId"] = image.id
        case .post(let post):   inputParams["postId"] = post.id
        }

        let tRPCInput = ["0": ["json": inputParams]]
        let bodyData = try JSONSerialization.data(withJSONObject: tRPCInput)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/CivitaiServiceManageCollectionsTests 2>&1 | tail -30`
Expected: all four tests in the suite pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/CivitaiService.swift DiffuselyTests/CivitaiServiceManageCollectionsTests.swift
git commit -m "Add CivitaiService.saveItem batched add/remove method"
```

---

## Task 5: Define `ManageCollectionsAPI` protocol

**Files:**
- Create: `Diffusely/Services/ManageCollectionsAPI.swift`
- Modify: `Diffusely/Services/CivitaiService.swift`

A minimal protocol of the methods the VM needs, so tests can substitute a fake. `CivitaiService` conforms via a single-line extension.

- [ ] **Step 1: Create the protocol file**

```swift
// Diffusely/Services/ManageCollectionsAPI.swift
import Foundation

/// Slice of `CivitaiService` that `ManageCollectionsViewModel` depends on.
/// Exists so VM tests can inject a fake; production code passes a real
/// `CivitaiService`.
@MainActor
protocol ManageCollectionsAPI {
    func getUserImageCollections() async throws -> [CivitaiCollection]
    func getUserPostCollections() async throws -> [CivitaiCollection]
    func getUserCollectionItemsByItem(target: ManageCollectionsTarget) async throws -> [Int]
    func saveItem(target: ManageCollectionsTarget, adding: [Int], removing: [Int]) async throws
}

extension CivitaiService: ManageCollectionsAPI {}
```

- [ ] **Step 2: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`. If the compiler complains that `CivitaiService` is not `@MainActor`, drop `@MainActor` from the protocol — the conformance is fine because the existing methods are already isolated as needed.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Services/ManageCollectionsAPI.swift
git commit -m "Add ManageCollectionsAPI protocol for VM dependency injection"
```

---

## Task 6: Build `ManageCollectionsViewModel`

**Files:**
- Create: `Diffusely/Services/ManageCollectionsViewModel.swift`
- Create: `DiffuselyTests/ManageCollectionsViewModelTests.swift`

The VM holds membership state, fires the parallel load, drives the optimistic toggle flow, and writes through to the local cache. Tests use a fake `ManageCollectionsAPI` with continuations so they can deterministically interleave events.

- [ ] **Step 1: Create the failing test file**

```swift
// DiffuselyTests/ManageCollectionsViewModelTests.swift
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
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/ManageCollectionsViewModelTests 2>&1 | tail -30`
Expected: build error — `ManageCollectionsViewModel` not defined.

- [ ] **Step 3: Implement the view model**

```swift
// Diffusely/Services/ManageCollectionsViewModel.swift
import Foundation
import SwiftUI

@MainActor
final class ManageCollectionsViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var collections: [CivitaiCollection] = []
    @Published private(set) var membership: Set<Int> = []
    @Published private(set) var pendingFlips: Set<Int> = []
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var rowErrors: [Int: String] = [:]

    let target: ManageCollectionsTarget
    private let api: ManageCollectionsAPI
    private let persistence: CollectionPersistenceService

    init(
        target: ManageCollectionsTarget,
        api: ManageCollectionsAPI,
        persistence: CollectionPersistenceService
    ) {
        self.target = target
        self.api = api
        self.persistence = persistence
    }

    /// Fetches the user's collections and current membership in parallel.
    /// Sets `loadState` to `.loaded` on success or `.failed` if either call throws.
    func load() async {
        loadState = .loading
        do {
            async let collectionsTask: [CivitaiCollection] = {
                switch target {
                case .image: return try await api.getUserImageCollections()
                case .post:  return try await api.getUserPostCollections()
                }
            }()
            async let membershipTask: [Int] = api.getUserCollectionItemsByItem(target: target)

            let (cols, member) = try await (collectionsTask, membershipTask)
            self.collections = sortCollections(cols)
            self.membership = Set(member)
            self.loadState = .loaded
        } catch {
            self.loadState = .failed(loadErrorMessage(error))
        }
    }

    /// Flips the row's membership optimistically, writes through to the local
    /// cache, and fires `saveItem`. Reverts both on failure.
    func toggle(_ collection: CivitaiCollection) async {
        let id = collection.id
        guard !pendingFlips.contains(id) else { return }
        pendingFlips.insert(id)
        rowErrors[id] = nil

        let wasIn = membership.contains(id)
        let willBeIn = !wasIn

        // Optimistic state and cache write-through.
        if willBeIn {
            membership.insert(id)
            applyCacheAdd(collectionId: id)
        } else {
            membership.remove(id)
            applyCacheRemove(collectionId: id)
        }

        do {
            try await api.saveItem(
                target: target,
                adding: willBeIn ? [id] : [],
                removing: willBeIn ? [] : [id]
            )
        } catch {
            // Revert state and cache.
            if willBeIn {
                membership.remove(id)
                applyCacheRemove(collectionId: id)
            } else {
                membership.insert(id)
                applyCacheAdd(collectionId: id)
            }
            rowErrors[id] = rowErrorMessage(error)
        }
        pendingFlips.remove(id)
    }

    // MARK: - Helpers

    private func applyCacheAdd(collectionId: Int) {
        switch target {
        case .image(let image):
            persistence.addImageStub(image, toCollectionId: collectionId)
        case .post(let post):
            persistence.addPostStub(post, toCollectionId: collectionId)
        }
    }

    private func applyCacheRemove(collectionId: Int) {
        switch target {
        case .image(let image):
            persistence.removeImage(imageId: image.id, fromCollectionId: collectionId)
        case .post(let post):
            persistence.removePost(postId: post.id, fromCollectionId: collectionId)
        }
    }

    /// Sorts by cached `listOrder` when a `PersistedCollection` exists, then
    /// alphabetical fallback for un-cached collections (which append at the end).
    private func sortCollections(_ input: [CivitaiCollection]) -> [CivitaiCollection] {
        let withOrder: [(CivitaiCollection, Int?)] = input.map { col in
            let listOrder = persistence.getPersistedCollection(id: col.id)?.listOrder
            return (col, listOrder)
        }
        return withOrder.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true            // cached rows first
            case (nil, _?):    return false
            case (nil, nil):
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
        }.map(\.0)
    }

    private func loadErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return "Sign in to manage collections"
        }
        return "Couldn't load collections"
    }

    private func rowErrorMessage(_ error: Error) -> String {
        "Couldn't update. Tap to retry."
    }

    /// Called after `CreateCollectionView` returns a freshly-created collection.
    /// Inserts it into the local cache and the visible list, then fires
    /// `saveItem` to add the current item to it. On failure the collection
    /// stays in the list but does not appear in `membership`.
    func addNewCollection(_ newCollection: CivitaiCollection) async {
        _ = persistence.getOrCreateCollection(from: newCollection)

        // Insert at the top of the list so the user sees their action's result.
        if !collections.contains(where: { $0.id == newCollection.id }) {
            collections.insert(newCollection, at: 0)
        }
        membership.insert(newCollection.id)
        applyCacheAdd(collectionId: newCollection.id)
        pendingFlips.insert(newCollection.id)
        rowErrors[newCollection.id] = nil

        do {
            try await api.saveItem(
                target: target,
                adding: [newCollection.id],
                removing: []
            )
        } catch {
            membership.remove(newCollection.id)
            applyCacheRemove(collectionId: newCollection.id)
            rowErrors[newCollection.id] = rowErrorMessage(error)
        }
        pendingFlips.remove(newCollection.id)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/ManageCollectionsViewModelTests 2>&1 | tail -30`
Expected: all eight tests pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/ManageCollectionsViewModel.swift DiffuselyTests/ManageCollectionsViewModelTests.swift
git commit -m "Add ManageCollectionsViewModel with load/toggle + write-through"
```

---

## Task 7: Build `ManageCollectionsSheet` view

**Files:**
- Create: `Diffusely/Views/ManageCollectionsSheet.swift`

The SwiftUI view that owns the VM and renders the list, including the "New Collection…" row that presents `CreateCollectionView`. No automated tests for the view itself; correctness is verified by the build succeeding plus the per-call-site migration tasks that follow.

**Note on `CreateCollectionView`'s shape:** its public init is `CreateCollectionView(onCreated: (Int) -> Void)` — it returns only the new collection's id and dismisses itself via `@Environment(\.dismiss)`. So the sheet must fetch the full `CivitaiCollection` via `civitaiService.getCollectionById(id:)` before handing it to `addNewCollection(_:)`.

- [ ] **Step 1: Create the view**

```swift
// Diffusely/Views/ManageCollectionsSheet.swift
import SwiftUI
import SwiftData

struct ManageCollectionsSheet: View {
    let target: ManageCollectionsTarget
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var civitaiService = CivitaiService()
    @State private var viewModel: ManageCollectionsViewModel?
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Manage Collections")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { onDismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 560)
        #endif
        .task {
            if viewModel == nil {
                let persistence = CollectionPersistenceService(modelContext: modelContext)
                viewModel = ManageCollectionsViewModel(
                    target: target,
                    api: civitaiService,
                    persistence: persistence
                )
            }
            await viewModel?.load()
        }
        .sheet(isPresented: $showingCreate) {
            CreateCollectionView(onCreated: { newId in
                Task {
                    // CreateCollectionView gives us only the id; fetch the full
                    // model so the VM has name/type/description for its row.
                    if let full = try? await civitaiService.getCollectionById(id: newId) {
                        await viewModel?.addNewCollection(full)
                    }
                }
            })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            switch vm.loadState {
            case .loading:
                ProgressView("Loading collections…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(message)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                List {
                    Button(action: { showingCreate = true }) {
                        Label("New Collection…", systemImage: "folder.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                    if vm.collections.isEmpty {
                        Section {
                            VStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                                Text("No \(target.displayName) collections found")
                                    .foregroundColor(.secondary)
                                Text("Create one to add this \(target.displayName) to it.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    } else {
                        ForEach(vm.collections) { collection in
                            collectionRow(collection, vm: vm)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: CivitaiCollection, vm: ManageCollectionsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { vm.membership.contains(collection.id) },
                set: { _ in Task { await vm.toggle(collection) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name)
                    if let desc = collection.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .disabled(vm.pendingFlips.contains(collection.id))

            if let message = vm.rowErrors[collection.id] {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .onTapGesture {
                    Task { await vm.toggle(collection) }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/ManageCollectionsSheet.swift
git commit -m "Add ManageCollectionsSheet view"
```

---

## Task 8: Migrate `ImageDetailView` call site

**Files:**
- Modify: `Diffusely/Views/ImageDetailView.swift`

Swap `CollectionPickerView` for `ManageCollectionsSheet`, change the menu label, and change the icon. Keep the `showingCollectionPicker` `@State` name as-is for minimal diff.

- [ ] **Step 1: Replace the menu Button**

Find this block in `ImageDetailView.swift` (currently around line 84):

```swift
                        if APIKeyManager.shared.hasAPIKey {
                            Button(action: {
                                showingCollectionPicker = true
                            }) {
                                Label("Add to Collection", systemImage: "folder.badge.plus")
                            }
                        }
```

Replace with:

```swift
                        if APIKeyManager.shared.hasAPIKey {
                            Button(action: {
                                showingCollectionPicker = true
                            }) {
                                Label("Manage Collections", systemImage: "folder")
                            }
                        }
```

- [ ] **Step 2: Replace the `.sheet` modifier**

Find this block (currently around line 163):

```swift
            .sheet(isPresented: $showingCollectionPicker) {
                CollectionPickerView(itemType: .image(id: image.id)) {
                    showingCollectionPicker = false
                }
            }
```

Replace with:

```swift
            .sheet(isPresented: $showingCollectionPicker) {
                ManageCollectionsSheet(target: .image(image)) {
                    showingCollectionPicker = false
                }
            }
```

- [ ] **Step 3: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/ImageDetailView.swift
git commit -m "Migrate ImageDetailView to ManageCollectionsSheet"
```

---

## Task 9: Migrate `PostDetailView` call site

**Files:**
- Modify: `Diffusely/Views/PostDetailView.swift`

- [ ] **Step 1: Replace the menu Button**

Find this block in `PostDetailView.swift` (currently around line 116):

```swift
                        if APIKeyManager.shared.hasAPIKey {
                            Button(action: {
                                showingCollectionPicker = true
                            }) {
                                Label("Add to Collection", systemImage: "folder.badge.plus")
                            }
                        }
```

Replace with:

```swift
                        if APIKeyManager.shared.hasAPIKey {
                            Button(action: {
                                showingCollectionPicker = true
                            }) {
                                Label("Manage Collections", systemImage: "folder")
                            }
                        }
```

- [ ] **Step 2: Replace the `.sheet` modifier**

Find this block (currently around line 266):

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .post(id: post.id)) {
                showingCollectionPicker = false
            }
        }
```

Replace with:

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .post(post)) {
                showingCollectionPicker = false
            }
        }
```

- [ ] **Step 3: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/PostDetailView.swift
git commit -m "Migrate PostDetailView to ManageCollectionsSheet"
```

---

## Task 10: Migrate `ImageFeedItemView` call site

**Files:**
- Modify: `Diffusely/Views/ImageFeedItemView.swift`

- [ ] **Step 1: Replace the menu Button**

Find this block in `ImageFeedItemView.swift` (currently around line 146):

```swift
        if APIKeyManager.shared.hasAPIKey {
            Button(action: {
                showingCollectionPicker = true
            }) {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
        }
```

Replace with:

```swift
        if APIKeyManager.shared.hasAPIKey {
            Button(action: {
                showingCollectionPicker = true
            }) {
                Label("Manage Collections", systemImage: "folder")
            }
        }
```

- [ ] **Step 2: Replace the `.sheet` modifier**

Find this block (currently around line 85):

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .image(id: image.id)) {
                showingCollectionPicker = false
            }
        }
```

Replace with:

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .image(image)) {
                showingCollectionPicker = false
            }
        }
```

- [ ] **Step 3: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/ImageFeedItemView.swift
git commit -m "Migrate ImageFeedItemView to ManageCollectionsSheet"
```

---

## Task 11: Migrate `PostsFeedItemView` call site

**Files:**
- Modify: `Diffusely/Views/PostsFeedItemView.swift`

- [ ] **Step 1: Replace the menu Button**

Find this block in `PostsFeedItemView.swift` (currently around line 162):

```swift
        if APIKeyManager.shared.hasAPIKey {
            Menu {
                Button(action: {
                    showingCollectionPicker = true
                }) {
                    Label("Add to Collection", systemImage: "folder.badge.plus")
                }
            } label: {
```

Replace the `Label` line only:

```swift
                    Label("Manage Collections", systemImage: "folder")
```

(Leave the surrounding `Menu` / `Button` / `} label: {` structure unchanged.)

- [ ] **Step 2: Replace the `.sheet` modifier**

Find this block (currently around line 148):

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .post(id: post.id)) {
                showingCollectionPicker = false
            }
        }
```

Replace with:

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .post(post)) {
                showingCollectionPicker = false
            }
        }
```

- [ ] **Step 3: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/PostsFeedItemView.swift
git commit -m "Migrate PostsFeedItemView to ManageCollectionsSheet"
```

---

## Task 12: Migrate `PostThumbnailView` call site (inside `AuthorContentGrid.swift`)

**Files:**
- Modify: `Diffusely/Views/AuthorContentGrid.swift`

`PostThumbnailView` is a sub-view inside `AuthorContentGrid.swift`. It has its own `showingCollectionPicker` state and presents the picker from a context menu. Only the menu label + sheet need to change here; the `onRequestRemove` context-menu plumbing is removed in Task 13.

- [ ] **Step 1: Replace the menu Button**

Find this block in `AuthorContentGrid.swift` (currently around line 141, inside `PostThumbnailView.menuContent`):

```swift
        if APIKeyManager.shared.hasAPIKey {
            Button {
                showingCollectionPicker = true
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
        }
```

Replace with:

```swift
        if APIKeyManager.shared.hasAPIKey {
            Button {
                showingCollectionPicker = true
            } label: {
                Label("Manage Collections", systemImage: "folder")
            }
        }
```

- [ ] **Step 2: Replace the `.sheet` modifier**

Find this block (currently around line 121, inside `PostThumbnailView.bodyCore`):

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .post(id: post.id)) {
                showingCollectionPicker = false
            }
        }
```

Replace with:

```swift
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .post(post)) {
                showingCollectionPicker = false
            }
        }
```

- [ ] **Step 3: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/AuthorContentGrid.swift
git commit -m "Migrate PostThumbnailView to ManageCollectionsSheet"
```

---

## Task 13: Replace `CollectionDetailView`'s remove flow; drop `onRequestRemove` plumbing

**Files:**
- Modify: `Diffusely/Views/CollectionDetailView.swift`
- Modify: `Diffusely/Views/AuthorContentGrid.swift`
- Modify: `Diffusely/Views/ImageFeedItemView.swift`

The per-item "Remove from Collection" context-menu entry is replaced by a "Manage Collections" entry that opens the new sheet for that item. The `pendingRemoval` / `removalError` / `performRemoval` state and the confirmation dialog all go away. With no caller passing `onRequestRemove`, the parameter and its associated `menuContent` branches in `AuthorContentGrid.PostThumbnailView` and `ImageFeedItemView` are deleted.

The plumbing change cascades: `AuthorContentGrid` loses its `onRequestRemove` param, the children's `onRequestRemove` plumbing collapses, and `ImageFeedItemView`/`PostThumbnailView` lose the `if onRequestRemove != nil` context-menu opt-in. Since the opt-in was the only thing controlling whether the context menu appeared at all, `CollectionDetailView`'s thumbnails would no longer have a context menu after this change — and we want them to (so the user can reach "Manage Collections" from a long-press). So `ImageFeedItemView` and `PostThumbnailView` gain a new opt-in parameter `var showsContextMenu: Bool = false` that the parent sets when it wants the menu to appear.

- [ ] **Step 1: Update `ImageFeedItemView` — replace `onRequestRemove` with `showsContextMenu`**

In `Diffusely/Views/ImageFeedItemView.swift`:

(a) Replace this parameter declaration (currently around line 18):

```swift
    /// When provided, the item gains a right-click / long-press context menu
    /// that mirrors the ellipsis overlay AND appends "Remove from Collection".
    /// Set only by collection-grid callers; nil elsewhere keeps the main feed
    /// and author profile context-menu-free.
    var onRequestRemove: (() -> Void)? = nil
```

With:

```swift
    /// When true, the item gains a right-click / long-press context menu
    /// that mirrors the ellipsis overlay. Set only by collection-grid callers;
    /// false elsewhere keeps the main feed and author profile context-menu-free.
    var showsContextMenu: Bool = false
```

(b) Replace this body wrapper (currently around line 59):

```swift
    @ViewBuilder
    var body: some View {
        if onRequestRemove != nil {
            bodyCore.contextMenu { menuContent }
        } else {
            bodyCore
        }
    }
```

With:

```swift
    @ViewBuilder
    var body: some View {
        if showsContextMenu {
            bodyCore.contextMenu { menuContent }
        } else {
            bodyCore
        }
    }
```

(c) Delete this trailing block from `menuContent` (currently around line 154):

```swift
        if APIKeyManager.shared.hasAPIKey, let onRequestRemove {
            Divider()
            Button(role: .destructive, action: onRequestRemove) {
                Label("Remove from Collection", systemImage: "trash")
            }
        }
```

- [ ] **Step 2: Update `PostThumbnailView` (in `AuthorContentGrid.swift`) — same swap**

In `Diffusely/Views/AuthorContentGrid.swift`:

(a) Replace this parameter (currently around line 55):

```swift
    /// When provided, the thumbnail gains a right-click / long-press context
    /// menu that mirrors `PostDetailView`'s "…" menu AND appends "Remove from
    /// Collection". Set only by the collection grid.
    var onRequestRemove: (() -> Void)? = nil
```

With:

```swift
    /// When true, the thumbnail gains a right-click / long-press context
    /// menu that mirrors `PostDetailView`'s "…" menu. Set only by the
    /// collection grid.
    var showsContextMenu: Bool = false
```

(b) Replace this body wrapper (currently around line 63):

```swift
    @ViewBuilder
    var body: some View {
        if onRequestRemove != nil {
            bodyCore.contextMenu { menuContent }
        } else {
            bodyCore
        }
    }
```

With:

```swift
    @ViewBuilder
    var body: some View {
        if showsContextMenu {
            bodyCore.contextMenu { menuContent }
        } else {
            bodyCore
        }
    }
```

(c) Delete this trailing block from `PostThumbnailView.menuContent` (currently around line 149):

```swift
        if APIKeyManager.shared.hasAPIKey, let onRequestRemove {
            Divider()
            Button(role: .destructive, action: onRequestRemove) {
                Label("Remove from Collection", systemImage: "trash")
            }
        }
```

- [ ] **Step 3: Update `AuthorContentGrid` — drop `onRequestRemove`, pass `showsContextMenu`**

Still in `Diffusely/Views/AuthorContentGrid.swift`. Replace the whole struct definition (currently lines 3-44):

```swift
struct AuthorContentGrid: View {
    let images: [CivitaiImage]
    let posts: [CivitaiPost]
    let collectionType: String
    var onRequestRemove: ((CollectionItemType) -> Void)? = nil
    /// Provided by the parent on Mac so taps push at the parent's level rather
    /// than at the root (where `feedNavigator.push` would clobber the parent's
    /// own stack entry). Nil on iOS — the children fall back to fullScreenCover.
    var onSelectImage: ((CivitaiImage) -> Void)? = nil
    var onSelectPost: ((CivitaiPost) -> Void)? = nil

    var body: some View {
        if collectionType == "Image" {
            MasonryGrid(
                items: images,
                aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
            ) { image in
                ImageFeedItemView(
                    image: image,
                    isGridMode: true,
                    preserveAspectRatio: true,
                    onSelectImage: onSelectImage.map { selector in { selector(image) } },
                    onRequestRemove: onRequestRemove.map { rm in { rm(.image(id: image.id)) } }
                )
            }
        } else {
            MasonryGrid(
                items: posts,
                aspectRatio: { post in
                    guard let first = post.safeImages.first, first.height > 0 else { return 1 }
                    return CGFloat(first.width) / CGFloat(first.height)
                }
            ) { post in
                PostThumbnailView(
                    post: post,
                    onSelect: onSelectPost.map { selector in { selector(post) } },
                    onRequestRemove: onRequestRemove.map { rm in { rm(.post(id: post.id)) } }
                )
            }
        }
    }
}
```

With:

```swift
struct AuthorContentGrid: View {
    let images: [CivitaiImage]
    let posts: [CivitaiPost]
    let collectionType: String
    /// When true, each thumbnail shows a context menu. Set only by the
    /// collection grid so the main feed and author profile remain clean.
    var showsItemContextMenus: Bool = false
    /// Provided by the parent on Mac so taps push at the parent's level rather
    /// than at the root (where `feedNavigator.push` would clobber the parent's
    /// own stack entry). Nil on iOS — the children fall back to fullScreenCover.
    var onSelectImage: ((CivitaiImage) -> Void)? = nil
    var onSelectPost: ((CivitaiPost) -> Void)? = nil

    var body: some View {
        if collectionType == "Image" {
            MasonryGrid(
                items: images,
                aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
            ) { image in
                ImageFeedItemView(
                    image: image,
                    isGridMode: true,
                    preserveAspectRatio: true,
                    onSelectImage: onSelectImage.map { selector in { selector(image) } },
                    showsContextMenu: showsItemContextMenus
                )
            }
        } else {
            MasonryGrid(
                items: posts,
                aspectRatio: { post in
                    guard let first = post.safeImages.first, first.height > 0 else { return 1 }
                    return CGFloat(first.width) / CGFloat(first.height)
                }
            ) { post in
                PostThumbnailView(
                    post: post,
                    onSelect: onSelectPost.map { selector in { selector(post) } },
                    showsContextMenu: showsItemContextMenus
                )
            }
        }
    }
}
```

- [ ] **Step 4: Update `CollectionDetailView` — delete remove state and pass `showsItemContextMenus: true`**

The per-thumbnail "Manage Collections" entry already opens `ManageCollectionsSheet` from each thumbnail's own `.sheet` (wired in Tasks 10 and 12). So `CollectionDetailView` itself does not need to present the sheet — it just needs to stop driving the now-gone remove confirmation, and pass `showsItemContextMenus: true` down to the grid.

In `Diffusely/Views/CollectionDetailView.swift`:

(a) Delete these three `@State` declarations (currently around line 22):

```swift
    // Removal state
    @State private var pendingRemoval: CollectionItemType?
    @State private var isRemoving = false
    @State private var removalError: String?
```

(b) Delete the `.confirmationDialog` and `.alert` blocks (currently around line 142):

```swift
        .confirmationDialog(
            "Remove from \"\(collection.name)\"?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval {
                    pendingRemoval = nil
                    Task { await performRemoval(item) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        }
        .alert(
            "Couldn't Remove Item",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
```

(c) Delete the `performRemoval` method entirely (currently around line 403):

```swift
    private func performRemoval(_ item: CollectionItemType) async {
        guard let persistenceService = persistenceService else { return }

        isRemoving = true
        defer { isRemoving = false }

        do {
            switch item {
            case .image(let imageId):
                try await civitaiService.removeImageFromCollection(imageId: imageId, collectionId: collection.id)
                persistenceService.removeImage(imageId: imageId, fromCollectionId: collection.id)
            case .post(let postId):
                try await civitaiService.removePostFromCollection(postId: postId, collectionId: collection.id)
                persistenceService.removePost(postId: postId, fromCollectionId: collection.id)
            }
            await reloadContent()
        } catch {
            removalError = "Failed to remove from collection: \(error.localizedDescription)"
        }
    }
```

(d) Update every `AuthorContentGrid(...)` call site in the file (find with `grep -n "AuthorContentGrid(" Diffusely/Views/CollectionDetailView.swift`). Each one currently has an `onRequestRemove: { pendingRemoval = $0 }` argument that needs to become `showsItemContextMenus: true`. For example, this block:

```swift
            AuthorContentGrid(
                images: images,
                posts: [],
                collectionType: "Image",
                onRequestRemove: { pendingRemoval = $0 },
                onSelectImage: macImageSelector,
                onSelectPost: macPostSelector
            )
```

becomes:

```swift
            AuthorContentGrid(
                images: images,
                posts: [],
                collectionType: "Image",
                showsItemContextMenus: true,
                onSelectImage: macImageSelector,
                onSelectPost: macPostSelector
            )
```

Do this for every `AuthorContentGrid(` invocation in the file.

- [ ] **Step 5: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`. If the compiler reports unused private members (`reloadContent` referenced only by deleted `performRemoval`, etc.), those references should still be wired elsewhere — investigate before deleting them.

- [ ] **Step 6: Smoke-check the existing tests still pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/MultiCollectionMembershipTests 2>&1 | tail -20`
Expected: all six tests still pass (we didn't touch the persistence service).

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Views/CollectionDetailView.swift Diffusely/Views/AuthorContentGrid.swift Diffusely/Views/ImageFeedItemView.swift
git commit -m "Replace CollectionDetailView remove flow with Manage Collections sheet"
```

---

## Task 14: Delete `CollectionPickerView` and obsolete service methods

**Files:**
- Delete: `Diffusely/Views/CollectionPickerView.swift`
- Modify: `Diffusely/Services/CivitaiService.swift`

After all six call sites migrated, `CollectionPickerView`, the `CollectionItemType` enum it defines, and the four single-direction service methods (`addImageToCollection`, `removeImageFromCollection`, `addPostToCollection`, `removePostFromCollection`) are unreferenced. Delete them.

- [ ] **Step 1: Confirm nothing still references the obsolete symbols**

Run:

```bash
grep -rn "CollectionPickerView\|CollectionItemType\|addImageToCollection\|removeImageFromCollection\|addPostToCollection\|removePostFromCollection" Diffusely DiffuselyTests
```

Expected: **no matches**. If anything is found, fix the caller before continuing — the deletes below will break the build otherwise.

- [ ] **Step 2: Delete the picker view file**

```bash
rm Diffusely/Views/CollectionPickerView.swift
```

- [ ] **Step 3: Delete the four obsolete service methods**

In `Diffusely/Services/CivitaiService.swift`, delete:

- `func addImageToCollection(imageId:collectionId:)` (currently around lines 711-762)
- `func removeImageFromCollection(imageId:collectionId:)` (currently around lines 764-814)
- `func addPostToCollection(postId:collectionId:)` (currently around lines 867-917)
- `func removePostFromCollection(postId:collectionId:)` (currently around lines 919-968)

Each method spans from its `func` declaration through the matching closing brace.

- [ ] **Step 4: Verify the project builds**

Run: `xcodebuild -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite once**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40`
Expected: all suites pass. This is the only full-suite run in the plan — a final sanity check before the cleanup commit.

- [ ] **Step 6: Commit**

```bash
git add -A Diffusely/Views/CollectionPickerView.swift Diffusely/Services/CivitaiService.swift
git commit -m "Remove CollectionPickerView and obsolete add/remove service methods"
```

---

## Done

After Task 14:

- One sheet (`ManageCollectionsSheet`) handles add and remove for all six entry points.
- Membership is fetched live from `collection.getUserCollectionItemsByItem`.
- Writes are batched via `collection.saveItem` with optimistic UI and local cache write-through.
- `CollectionPickerView` and four single-direction service methods are gone.

Run the manual smoke-test checklist from the spec before opening a PR:

1. Add a single new collection from inline "New Collection…" while item is in zero collections.
2. Toggle on then off rapidly on the same collection.
3. Toggle on a collection while offline → row error, toggle reverts.
4. Open on an item already in 3 of 5 collections → 3 toggles on, 2 off.
5. Open from inside `CollectionDetailView`'s per-item menu → current collection's toggle is on; flipping it off removes from the visible grid.
6. macOS: window sizing matches the old picker.
