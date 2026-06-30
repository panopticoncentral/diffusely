# Clickable Tags on Image/Video Detail — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an image/video's tags on its detail view and make each tag tappable, opening a tag-filtered feed with the usual sort/timeframe controls.

**Architecture:** Fetch the server-curated tag list via Civitai's `tag.getVotableTags` (mirroring civitai.com, which denoises tags server-side). Display the curated tags as chips on `ImageDetailView`, collapsed to 6 with "Show more". Tapping a chip opens a new `TagFeedView` — modeled on the existing `UserContentView` scoped-feed pattern — that calls the existing feed fetch with a new `tags: [Int]` filter, fixed to the tapped media type.

**Tech Stack:** Swift, SwiftUI (iOS 18.5 / macOS 15 targets), swift-testing, tRPC-over-HTTP GET requests. New files are auto-included via the project's file-system-synchronized groups (no `.xcodeproj` edits needed).

**Spec:** `docs/superpowers/specs/2026-06-30-clickable-tags-design.md`

---

## File structure

- **Create** `Diffusely/Models/Civitai/CivitaiVotableTag.swift` — the tag model.
- **Modify** `Diffusely/Services/Networking/CivitaiService.swift` — add `fetchVotableTags(imageId:)` and a `tags: [Int]?` filter on `fetchImages`/`loadMoreImages`.
- **Create** `Diffusely/Views/TagsSectionView.swift` — the detail-view "Tags" section (chips + "Show more") and a small `FlowLayout`.
- **Create** `Diffusely/Views/TagFeedView.swift` — the tag-filtered feed screen.
- **Modify** `Diffusely/Views/ImageDetailView.swift` — load tags, render the section, present the tag feed.
- **Create** `DiffuselyTests/CivitaiVotableTagTests.swift` — model decode + service ordering/filter tests.
- **Create** `DiffuselyTests/CivitaiServiceTagFeedTests.swift` — `tags` appears in the feed request.

### Test / build commands used throughout

- Run a specific test suite (fast, macOS, no simulator):
  `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/<SuiteName>`
- Compile-check iOS:
  `xcodebuild build -scheme Diffusely -destination 'generic/platform=iOS'`

---

## Task 1: CivitaiVotableTag model

**Files:**
- Create: `Diffusely/Models/Civitai/CivitaiVotableTag.swift`
- Test: `DiffuselyTests/CivitaiVotableTagTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/CivitaiVotableTagTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct CivitaiVotableTagTests {
    @Test func decodesTagObjectIgnoringExtraKeys() throws {
        let json = Data(#"""
        {"id":4,"name":"anime","type":"Label","nsfwLevel":1,"score":42,"upVotes":50,"downVotes":8,"automated":true}
        """#.utf8)

        let tag = try JSONDecoder().decode(CivitaiVotableTag.self, from: json)

        #expect(tag.id == 4)
        #expect(tag.name == "anime")
        #expect(tag.type == "Label")
        #expect(tag.nsfwLevel == 1)
        #expect(tag.score == 42)
    }

    @Test func decodesArray() throws {
        let json = Data(#"""
        [{"id":4,"name":"anime","type":"Label","nsfwLevel":1,"score":42},
         {"id":5,"name":"nudity","type":"Moderation","nsfwLevel":4,"score":10}]
        """#.utf8)

        let tags = try JSONDecoder().decode([CivitaiVotableTag].self, from: json)

        #expect(tags.count == 2)
        #expect(tags[1].name == "nudity")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/CivitaiVotableTagTests`
Expected: FAIL — build error, `cannot find 'CivitaiVotableTag' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Diffusely/Models/Civitai/CivitaiVotableTag.swift`:

```swift
import Foundation

/// A tag on an image/video, as returned by Civitai's `tag.getVotableTags`.
/// Civitai treats videos as images, so the same endpoint serves both.
/// The server already curates this list (suppressing noisy auto-tags); we only
/// display the result and filter feeds by `id`.
struct CivitaiVotableTag: Codable, Identifiable, Hashable {
    let id: Int          // drives both the feed filter and the SwiftUI list key
    let name: String     // chip label
    let type: String     // "UserGenerated" | "Label" | "Moderation" | "System"
    let nsfwLevel: Int
    let score: Int
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/CivitaiVotableTagTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/Civitai/CivitaiVotableTag.swift DiffuselyTests/CivitaiVotableTagTests.swift
git commit -m "Add CivitaiVotableTag model

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `fetchVotableTags` service method

Fetches the curated tag list, orders it moderation-first then by descending score, drops non-filterable tags (`id <= 0`), and returns `[]` on any error (tags are non-critical — the detail view hides the section when empty).

**Files:**
- Modify: `Diffusely/Services/Networking/CivitaiService.swift`
- Test: `DiffuselyTests/CivitaiVotableTagTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `DiffuselyTests/CivitaiVotableTagTests.swift` (add these inside the file, after the existing `@Suite` struct):

```swift
/// Dedicated URLProtocol stub for the votable-tags suite so its handler can't
/// race with stubs other suites install. Mirrors the StubURLProtocol pattern
/// used across the service test suites.
final class StubVotableTagsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubVotableTagsURLProtocol.handler else {
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

@Suite(.serialized) @MainActor struct FetchVotableTagsTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubVotableTagsURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func ordersModerationFirstThenByScore() async {
        StubVotableTagsURLProtocol.handler = { _ in
            (200, Data(#"""
            [{"result":{"data":{"json":[
              {"id":4,"name":"anime","type":"Label","nsfwLevel":1,"score":90},
              {"id":5,"name":"nudity","type":"Moderation","nsfwLevel":4,"score":3},
              {"id":6,"name":"forest","type":"Label","nsfwLevel":1,"score":50}
            ]}}}]
            """#.utf8))
        }
        defer { StubVotableTagsURLProtocol.handler = nil }

        let tags = await makeService().fetchVotableTags(imageId: 1)

        #expect(tags.map(\.name) == ["nudity", "anime", "forest"])
    }

    @Test func dropsNonFilterableTags() async {
        StubVotableTagsURLProtocol.handler = { _ in
            (200, Data(#"""
            [{"result":{"data":{"json":[
              {"id":0,"name":"pending","type":"UserGenerated","nsfwLevel":1,"score":1},
              {"id":7,"name":"keep","type":"Label","nsfwLevel":1,"score":1}
            ]}}}]
            """#.utf8))
        }
        defer { StubVotableTagsURLProtocol.handler = nil }

        let tags = await makeService().fetchVotableTags(imageId: 1)

        #expect(tags.map(\.name) == ["keep"])
    }

    @Test func returnsEmptyOnServerError() async {
        StubVotableTagsURLProtocol.handler = { _ in (500, Data("error".utf8)) }
        defer { StubVotableTagsURLProtocol.handler = nil }

        let tags = await makeService().fetchVotableTags(imageId: 1)

        #expect(tags.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/FetchVotableTagsTests`
Expected: FAIL — build error, `value of type 'CivitaiService' has no member 'fetchVotableTags'`.

- [ ] **Step 3: Write minimal implementation**

In `Diffusely/Services/Networking/CivitaiService.swift`, add this method immediately after `fetchGenerationData(imageId:)` (which ends at line 375 with its closing `}`):

```swift
    /// Fetches the curated tag list for an image/video via `tag.getVotableTags`.
    /// The server denoises the list (suppressing auto-tags when better source
    /// tags exist). We order moderation tags first, then by descending score —
    /// matching civitai.com — and drop tags with no usable id (e.g. pending
    /// user tags), since a feed cannot be filtered by them. Returns `[]` on any
    /// error; tags are non-critical UI and the caller hides the section when empty.
    func fetchVotableTags(imageId: Int) async -> [CivitaiVotableTag] {
        do {
            var components = URLComponents(string: "\(baseURL)/tag.getVotableTags")!

            // `type: "image"` covers videos too (Civitai videos are images).
            let inputParams: [String: Any] = [
                "id": imageId,
                "type": "image",
            ]

            let tRPCInput = [
                "0": [
                    "json": inputParams
                ]
            ]

            let inputData = try JSONSerialization.data(withJSONObject: tRPCInput)
            let inputString = String(data: inputData, encoding: .utf8)!

            components.queryItems = [
                URLQueryItem(name: "batch", value: "1"),
                URLQueryItem(name: "input", value: inputString)
            ]

            guard let url = components.url else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            if let apiKey = APIKeyManager.shared.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await session.data(for: request)
            try validateStatus(response)

            struct TagsResponse: Codable {
                let result: TagsResult
            }
            struct TagsResult: Codable {
                let data: TagsData
            }
            struct TagsData: Codable {
                let json: [CivitaiVotableTag]
            }

            let tRPCResponse = try JSONDecoder().decode([TagsResponse].self, from: data)
            let tags = tRPCResponse[0].result.data.json

            return tags
                .filter { $0.id > 0 }
                .sorted { lhs, rhs in
                    let lhsMod = lhs.type == "Moderation"
                    let rhsMod = rhs.type == "Moderation"
                    if lhsMod != rhsMod { return lhsMod }
                    return lhs.score > rhs.score
                }
        } catch {
            return []
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/FetchVotableTagsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Networking/CivitaiService.swift DiffuselyTests/CivitaiVotableTagTests.swift
git commit -m "Add fetchVotableTags to CivitaiService

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `tags` filter on the feed fetch

Adds an optional `tags: [Int]?` to `fetchImages`/`loadMoreImages`. When present, the request filters by those tag IDs using the DB path (no `useIndex`) — matching civitai.com's `/images?tags=` behavior, where the Meilisearch index path does not apply the tag join.

**Files:**
- Modify: `Diffusely/Services/Networking/CivitaiService.swift:138` (fetchImages) and `:233` (loadMoreImages)
- Test: `DiffuselyTests/CivitaiServiceTagFeedTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/CivitaiServiceTagFeedTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

final class StubTagFeedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubTagFeedURLProtocol.handler else {
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

@Suite(.serialized) @MainActor struct CivitaiServiceTagFeedTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTagFeedURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func tagsFilterAppearsInRequestAndUsesDBPath() async throws {
        var capturedInput: String?
        StubTagFeedURLProtocol.handler = { request in
            capturedInput = request.url?.query?.removingPercentEncoding
            return (200, Data(#"[{"result":{"data":{"json":{"items":[],"nextCursor":null}}}}]"#.utf8))
        }
        defer { StubTagFeedURLProtocol.handler = nil }

        await makeService().fetchImages(videos: false, tags: [1234])

        let input = try #require(capturedInput)
        #expect(input.contains("\"tags\":[1234]"))
        // Tag feed must use the DB path, not the Meilisearch index.
        #expect(!input.contains("useIndex"))
    }

    @Test func noTagsKeyWhenFilterAbsent() async throws {
        var capturedInput: String?
        StubTagFeedURLProtocol.handler = { request in
            capturedInput = request.url?.query?.removingPercentEncoding
            return (200, Data(#"[{"result":{"data":{"json":{"items":[],"nextCursor":null}}}}]"#.utf8))
        }
        defer { StubTagFeedURLProtocol.handler = nil }

        await makeService().fetchImages(videos: false)

        let input = try #require(capturedInput)
        #expect(!input.contains("\"tags\""))
        #expect(input.contains("useIndex"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/CivitaiServiceTagFeedTests`
Expected: FAIL — build error, `extra argument 'tags' in call` (the `tags:` parameter does not exist yet).

- [ ] **Step 3: Write minimal implementation**

In `Diffusely/Services/Networking/CivitaiService.swift`, change the `fetchImages` signature at line 138 from:

```swift
    func fetchImages(videos: Bool, limit: Int = 20, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil) async {
```

to:

```swift
    func fetchImages(videos: Bool, limit: Int = 20, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil, tags: [Int]? = nil) async {
```

Then replace the collection/username branch (currently lines 163-170):

```swift
                if let collectionId = collectionId {
                    inputParams["collectionId"] = collectionId
                } else {
                    inputParams["useIndex"] = true
                    if let username = username {
                        inputParams["username"] = username
                    }
                }
```

with:

```swift
                if let collectionId = collectionId {
                    inputParams["collectionId"] = collectionId
                } else if let tags = tags, !tags.isEmpty {
                    // Tag-filtered feed: use the DB path (matches civitai.com's
                    // /images?tags=). The Meilisearch index path (useIndex) does
                    // not apply the TagsOnImageDetails join, so omit it here.
                    inputParams["tags"] = tags
                } else {
                    inputParams["useIndex"] = true
                    if let username = username {
                        inputParams["username"] = username
                    }
                }
```

Then change the `loadMoreImages` signature at line 233 from:

```swift
    func loadMoreImages(videos: Bool, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil) async {
        guard nextCursor != nil, !isLoading else { return }
        await fetchImages(videos: videos, period: period, sort: sort, collectionId: collectionId, username: username)
    }
```

to:

```swift
    func loadMoreImages(videos: Bool, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil, tags: [Int]? = nil) async {
        guard nextCursor != nil, !isLoading else { return }
        await fetchImages(videos: videos, period: period, sort: sort, collectionId: collectionId, username: username, tags: tags)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/CivitaiServiceTagFeedTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Networking/CivitaiService.swift DiffuselyTests/CivitaiServiceTagFeedTests.swift
git commit -m "Add tags filter to image feed fetch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: TagFeedView (tag-filtered feed screen)

A scoped feed modeled on `UserContentView`, simplified: a single fixed media type (no Images/Videos picker), no follow button, title = the tag name. iOS owns its chrome (close + title + filter menu); macOS uses the navigation title + toolbar, with the same `pushed*` local-state workaround `UserContentView` uses so tapping an image here doesn't collapse the stack.

**Files:**
- Create: `Diffusely/Views/TagFeedView.swift`

- [ ] **Step 1: Create the view**

Create `Diffusely/Views/TagFeedView.swift`:

```swift
import SwiftUI

/// A feed scoped to a single tag, opened by tapping a tag chip on a detail
/// view. Fixed to one media type (the type of the media the tag was tapped
/// from). Modeled on `UserContentView`'s scoped-feed pattern.
struct TagFeedView: View {
    let tagId: Int
    let tagName: String
    let videos: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var domainManager = DomainManager.shared
    @State private var selectedPeriod: Timeframe = .week
    @State private var selectedSort: FeedSort = .mostCollected

    #if os(macOS)
    // Route inner pushes through THIS view's stack slot rather than the
    // NavigationStack root, so back returns here. Matches UserContentView.
    @State private var pushedImage: CivitaiImage?
    @State private var pushedPost: CivitaiPost?
    #endif

    private var isGridLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            headerView
            #endif

            ScrollView {
                feedContent

                if civitaiService.isLoading {
                    ProgressView()
                        .padding()
                }

                if civitaiService.images.isEmpty && !civitaiService.isLoading {
                    emptyStateView
                }
            }
            .refreshable {
                await refreshContent()
            }
        }
        .background(Color(.systemBackground))
        #if os(macOS)
        .navigationTitle(tagName)
        .toolbar { macToolbar }
        #endif
        .task {
            await loadContent()
        }
        .onChange(of: selectedPeriod) { _, _ in
            Task { await refreshContent() }
        }
        .onChange(of: selectedSort) { _, _ in
            Task { await refreshContent() }
        }
        .onChange(of: domainManager.domain) { _, _ in
            Task { await refreshContent() }
        }
        #if os(macOS)
        .navigationDestination(item: $pushedImage) { image in
            ImageDetailView(image: image)
        }
        .navigationDestination(item: $pushedPost) { post in
            PostDetailView(post: post)
        }
        #endif
    }

    @ViewBuilder
    private var feedContent: some View {
        #if os(macOS)
        MasonryGrid(
            items: civitaiService.images,
            aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
        ) { image in
            ImageFeedItemView(
                image: image,
                isGridMode: true,
                preserveAspectRatio: true,
                onSelectImage: { pushedImage = image },
                onSelectUser: { _ in },
                onSelectPost: { pushedPost = $0 }
            )
            .onAppear {
                if image.id == civitaiService.images.last?.id {
                    Task { await loadMore() }
                }
            }
        }
        #else
        if isGridLayout {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(civitaiService.images) { image in
                    ImageFeedItemView(image: image, isGridMode: true)
                        .onAppear {
                            if image.id == civitaiService.images.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(civitaiService.images) { image in
                    ImageFeedItemView(image: image, isGridMode: false)
                        .onAppear {
                            if image.id == civitaiService.images.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")

            Spacer()

            Text(tagName)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            filterMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
    #endif

    /// Filter (time + sort) menu — shared between the iOS in-content header and
    /// the macOS toolbar. Matches UserContentView's menu.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Menu("Time") {
                ForEach(Timeframe.allCases) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        HStack {
                            Text(period.displayName)
                            if period == selectedPeriod {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("Sort") {
                ForEach(FeedSort.allCases) { sort in
                    Button {
                        selectedSort = sort
                    } label: {
                        HStack {
                            Text(sort.displayName)
                            Spacer()
                            if sort == selectedSort {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: sort.icon)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter and sort")
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            filterMenu
        }
    }
    #endif

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: videos ? "video" : "photo")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No \(videos ? "videos" : "images") found")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 60)
    }

    private func loadContent() async {
        await civitaiService.fetchImages(
            videos: videos,
            period: selectedPeriod,
            sort: selectedSort,
            tags: [tagId]
        )
    }

    private func loadMore() async {
        await civitaiService.loadMoreImages(
            videos: videos,
            period: selectedPeriod,
            sort: selectedSort,
            tags: [tagId]
        )
    }

    private func refreshContent() async {
        civitaiService.clear()
        await loadContent()
    }
}
```

- [ ] **Step 2: Compile-check both platforms**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild build -scheme Diffusely -destination 'generic/platform=iOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/TagFeedView.swift
git commit -m "Add TagFeedView for tag-filtered feeds

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: TagsSectionView + FlowLayout

The detail-view "Tags" section: a wrapping flow of chip buttons, collapsed to 6 with a "Show more" / "Show less" toggle. `FlowLayout` is a minimal wrapping layout (the project has none).

**Files:**
- Create: `Diffusely/Views/TagsSectionView.swift`

- [ ] **Step 1: Create the view + layout**

Create `Diffusely/Views/TagsSectionView.swift`:

```swift
import SwiftUI

/// The "Tags" section on the image/video detail view: tappable tag chips,
/// collapsed to `collapsedCount` with a "Show more" toggle. Empty handling is
/// the caller's job (it omits this view entirely when there are no tags).
struct TagsSectionView: View {
    let tags: [CivitaiVotableTag]
    @Binding var showAll: Bool
    let onSelect: (CivitaiVotableTag) -> Void

    private let collapsedCount = 6

    private var visibleTags: [CivitaiVotableTag] {
        if showAll || tags.count <= collapsedCount {
            return tags
        }
        return Array(tags.prefix(collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)
                .foregroundColor(.primary)

            FlowLayout(spacing: 8) {
                ForEach(visibleTags) { tag in
                    Button {
                        onSelect(tag)
                    } label: {
                        Text(tag.name)
                            .font(.caption)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if tags.count > collapsedCount {
                Button {
                    withAnimation { showAll.toggle() }
                } label: {
                    Text(showAll ? "Show less" : "Show more")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A simple wrapping flow layout: places subviews left-to-right, wrapping to a
/// new row when the current row runs out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)

        let resolvedWidth = (proposal.width == nil) ? totalWidth : maxWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
```

- [ ] **Step 2: Compile-check both platforms**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild build -scheme Diffusely -destination 'generic/platform=iOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/TagsSectionView.swift
git commit -m "Add TagsSectionView and FlowLayout for tag chips

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Wire tags into ImageDetailView

Load the tags, render the section after the generation-data section (hidden when empty), and present `TagFeedView` when a chip is tapped — iOS via `fullScreenCover`, macOS via `navigationDestination`, mirroring how this view already presents `UserContentView`.

**Files:**
- Modify: `Diffusely/Views/ImageDetailView.swift`

- [ ] **Step 1: Add state**

In `Diffusely/Views/ImageDetailView.swift`, after the existing state declarations (after line 22, `@ObservedObject private var librarySaveService = LibrarySaveService.shared`), add:

```swift
    @State private var tags: [CivitaiVotableTag] = []
    @State private var showAllTags = false
    #if os(iOS)
    @State private var selectedTag: CivitaiVotableTag?
    #else
    @State private var pushedTag: CivitaiVotableTag?
    #endif
```

- [ ] **Step 2: Render the Tags section**

In the stats `VStack` (lines 117-137), the generation-data block currently ends like this:

```swift
                            // Generation data section
                            if isLoadingGenData {
                                ProgressView()
                                    .padding()
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }
                        }
                        .padding()
```

Insert the Tags section between the gen-data `if/else` and the closing brace of the `VStack`:

```swift
                            // Generation data section
                            if isLoadingGenData {
                                ProgressView()
                                    .padding()
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }

                            // Tags section (hidden entirely when there are no
                            // tags or the fetch failed).
                            if !tags.isEmpty {
                                Divider()
                                TagsSectionView(tags: tags, showAll: $showAllTags) { tag in
                                    #if os(iOS)
                                    selectedTag = tag
                                    #else
                                    pushedTag = tag
                                    #endif
                                }
                            }
                        }
                        .padding()
```

- [ ] **Step 3: Load tags**

The view already has `.task { await loadGenerationData() }` at line 151. Immediately after it, add a second task:

```swift
            .task {
                tags = await civitaiService.fetchVotableTags(imageId: image.id)
            }
```

- [ ] **Step 4: Present the tag feed**

Add the macOS push destination next to the existing `pushedUser` destination. The existing block (lines 157-161) is:

```swift
            #if os(macOS)
            .navigationDestination(item: $pushedUser) { user in
                UserContentView(user: user)
            }
            #endif
```

Add a second destination right after it (inside a new `#if os(macOS)` block, or extend — use a separate block for clarity):

```swift
            #if os(macOS)
            .navigationDestination(item: $pushedTag) { tag in
                TagFeedView(tagId: tag.id, tagName: tag.name, videos: image.isVideo)
            }
            #endif
```

Add the iOS cover next to the existing `showingUserContent` cover. The existing block (lines 172-178) is:

```swift
            #if os(iOS)
            .fullScreenCover(isPresented: $showingUserContent) {
                if let user = image.user {
                    UserContentView(user: user)
                }
            }
            #endif
```

Add a second cover right after it:

```swift
            #if os(iOS)
            .fullScreenCover(item: $selectedTag) { tag in
                TagFeedView(tagId: tag.id, tagName: tag.name, videos: image.isVideo)
            }
            #endif
```

- [ ] **Step 5: Compile-check both platforms**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild build -scheme Diffusely -destination 'generic/platform=iOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Run the full unit-test suite**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests`
Expected: PASS (all suites, including the three new tag suites).

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Views/ImageDetailView.swift
git commit -m "Show clickable tags on image/video detail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Manual verification (both platforms)

The UI and the live tag filter cannot be unit-tested, so verify by hand. This also validates the spec's open question — that the `tags` filter returns correct results against the live API with `useIndex` omitted.

- [ ] **Step 1: iOS** — Run the app (`Diffusely` scheme, an iOS simulator). Open any image's detail view. Confirm:
  - A "Tags" section appears below Generation Info with up to 6 chips; "Show more" reveals the rest and "Show less" collapses them.
  - Tapping a chip opens a full-screen feed titled with the tag name, showing **images** (the media type you tapped from), populated with results.
  - The filter menu changes sort/timeframe and the feed refreshes.
  - Close returns to the image detail. Repeat from a **video** detail and confirm the tag feed shows **videos**.
  - An image with no curated tags shows **no** "Tags" section (no empty header).

- [ ] **Step 2: macOS** — Run the app on My Mac. Repeat the checks. Confirm the tag feed pushes onto the navigation stack with the tag name as the title and the filter menu in the toolbar, and that Back returns to the image detail (not past it to the root feed).

- [ ] **Step 3:** If the tag feed comes back empty on the live API despite the tag clearly having content, revisit the `useIndex`/`tags` interaction in Task 3 (try setting `inputParams["useIndex"] = false` explicitly, or compare the request against civitai.com's `/images?tags=` network call). Otherwise, the feature is complete.

---

## Self-review notes

- **Spec coverage:** model + `getVotableTags` fetch (Tasks 1-2), tag-filtered feed service (Task 3), `TagFeedView` (Task 4), detail-view section collapsed-to-6 with empty/error hidden (Tasks 5-6), presentation mirroring `UserContentView` with the macOS stack workaround (Tasks 4 & 6), single-tag / read-only / detail-only scope (no extra surfaces added). All covered.
- **Type consistency:** `CivitaiVotableTag(id,name,type,nsfwLevel,score)` is used identically across model, service decode, ordering, `TagsSectionView`, and `TagFeedView(tagId:tagName:videos:)`. The service `tags: [Int]?` parameter name matches between `fetchImages`, `loadMoreImages`, and both call sites in `TagFeedView`.
- **No placeholders:** every code and command step is concrete.
