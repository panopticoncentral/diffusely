# Library Sort & Grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add sort + grouping to `LibraryView`, mirroring the collection-view pattern with one extra dimension (group by checkpoint).

**Architecture:** Six-case `LibrarySort` enum (date asc/desc flat, author/checkpoint asc/desc grouped). A new `@MainActor LibrarySortService` queries `PersistedLibraryItem` and returns a `LibrarySortedContent` sum type (flat or grouped). Three new indexed columns (`publishedAt`, `authorAvatarURL`, `checkpointName`) are denormalized onto `PersistedLibraryItem` and the sidecar JSON is bumped to schema v3 to start storing `publishedAt`. A new `LibraryDateBackfillService` re-fetches old items missing the publish date via a new `CivitaiService.fetchImage(imageId:)` endpoint. `LibraryView` switches from `@Query` to manual sort/group rendering with pinned section headers.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing (`Testing` module), Civitai tRPC (`/api/trpc/image.get`).

**Source spec:** `docs/superpowers/specs/2026-05-20-library-sort-and-grouping-design.md`

**Test execution:** `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16'` with `-only-testing:DiffuselyTests/<SuiteName>` to scope. Tests use Swift Testing (`#expect`, `@Test`, `@Suite`).

---

## File Map

**Create:**
- `Diffusely/Models/LibrarySort.swift` — 6-case sort enum
- `Diffusely/Services/LibrarySortService.swift` — `@MainActor` read-side sort/group helper
- `Diffusely/Services/LibraryDateBackfillService.swift` — serial publish-date backfill queue
- `Diffusely/Views/LibrarySortMenu.swift` — toolbar `Menu` bound to `LibrarySort`
- `Diffusely/Views/LibraryGroupHeader.swift` — pinned header for checkpoint/bucket groups
- `DiffuselyTests/LibrarySortTests.swift` — sort/group rules
- `DiffuselyTests/LibraryDateBackfillTests.swift` — backfill rewrite + index update

**Modify:**
- `Diffusely/Models/LibraryItemMetadata.swift` — bump `currentSchemaVersion` to 3, add `publishedAt: Date?`
- `Diffusely/Models/Persistence/PersistedLibraryItem.swift` — add `publishedAt`, `authorAvatarURL`, `checkpointName`; denormalize in `init(metadata:)`
- `Diffusely/Services/LibraryIndexService.swift` — update three new columns on the "existing" branch of `ingest`
- `Diffusely/Services/LibrarySaveService.swift` — pass `image.publishedAtDate` into the metadata
- `Diffusely/Services/CivitaiService.swift` — add `fetchImage(imageId:)`
- `Diffusely/Services/LibrarySaveService.swift` — extend `LibraryFileWriter` with `rewriteMetadata`
- `Diffusely/Views/LibraryView.swift` — drop `@Query`, render sorted/grouped content, trigger backfill
- `DiffuselyTests/LibraryTests.swift` — extend the `makeMetadata` helper with `publishedAt`

---

## Task 1: `LibrarySort` enum

**Files:**
- Create: `Diffusely/Models/LibrarySort.swift`
- Test: `DiffuselyTests/LibrarySortTests.swift` (created; later tasks add more suites here)

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibrarySortTests.swift` with:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct LibrarySortEnumTests {
    @Test func hasSixCasesInExpectedOrder() {
        let cases = LibrarySort.allCases
        #expect(cases == [
            .dateNewest,
            .dateOldest,
            .authorAscending,
            .authorDescending,
            .checkpointAscending,
            .checkpointDescending
        ])
    }

    @Test func groupedHelpersClassifyEachCase() {
        #expect(LibrarySort.dateNewest.isGrouped == false)
        #expect(LibrarySort.dateOldest.isGrouped == false)
        #expect(LibrarySort.authorAscending.isAuthorGrouped == true)
        #expect(LibrarySort.authorDescending.isAuthorGrouped == true)
        #expect(LibrarySort.checkpointAscending.isCheckpointGrouped == true)
        #expect(LibrarySort.checkpointDescending.isCheckpointGrouped == true)

        #expect(LibrarySort.authorAscending.isCheckpointGrouped == false)
        #expect(LibrarySort.checkpointAscending.isAuthorGrouped == false)
    }

    @Test func ascendingFlagMatchesDirection() {
        #expect(LibrarySort.dateNewest.ascending == false)
        #expect(LibrarySort.dateOldest.ascending == true)
        #expect(LibrarySort.authorAscending.ascending == true)
        #expect(LibrarySort.authorDescending.ascending == false)
        #expect(LibrarySort.checkpointAscending.ascending == true)
        #expect(LibrarySort.checkpointDescending.ascending == false)
    }

    @Test func displayNamesAreHumanReadable() {
        #expect(LibrarySort.dateNewest.displayName == "Date (Newest)")
        #expect(LibrarySort.checkpointAscending.displayName == "Checkpoint (A–Z)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySortEnumTests`
Expected: build fails — `cannot find type 'LibrarySort' in scope`.

- [ ] **Step 3: Create the enum**

Create `Diffusely/Models/LibrarySort.swift`:

```swift
import Foundation

/// Sort options for the personal library. Flat enum (like `CollectionSort` and
/// `FeedSort`) so it drops into the menu/checkmark pattern and persists as a
/// `String` rawValue if we ever want to.
enum LibrarySort: String, CaseIterable, Identifiable, Equatable {
    case dateNewest           = "Date (Newest)"
    case dateOldest           = "Date (Oldest)"
    case authorAscending      = "Author (A–Z)"
    case authorDescending     = "Author (Z–A)"
    case checkpointAscending  = "Checkpoint (A–Z)"
    case checkpointDescending = "Checkpoint (Z–A)"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// True when this sort produces author-grouped sections.
    var isAuthorGrouped: Bool {
        self == .authorAscending || self == .authorDescending
    }

    /// True when this sort produces checkpoint-grouped sections.
    var isCheckpointGrouped: Bool {
        self == .checkpointAscending || self == .checkpointDescending
    }

    /// True for any grouped sort (author or checkpoint).
    var isGrouped: Bool { isAuthorGrouped || isCheckpointGrouped }

    /// For grouped sorts: section order. For date sorts: items oldest-first
    /// when true, newest-first when false.
    var ascending: Bool {
        switch self {
        case .dateOldest, .authorAscending, .checkpointAscending:   return true
        case .dateNewest, .authorDescending, .checkpointDescending: return false
        }
    }

    /// SF Symbol shown next to each menu item (replaced by a checkmark when
    /// selected). Mirrors `CollectionSort.icon`.
    var icon: String {
        switch self {
        case .dateNewest:           return "clock.fill"
        case .dateOldest:           return "calendar"
        case .authorAscending:      return "arrow.up"
        case .authorDescending:     return "arrow.down"
        case .checkpointAscending:  return "arrow.up"
        case .checkpointDescending: return "arrow.down"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySortEnumTests`
Expected: all 4 tests PASS.

> **Adding the file to the Xcode project:** new `.swift` files under `Diffusely/Models/` and `Diffusely/Services/` and `Diffusely/Views/` are usually picked up automatically by SwiftPM-style folder references. If `xcodebuild` reports "Cannot find ... in scope" *after* the file exists on disk, open the project in Xcode once so it indexes the new file (or add it explicitly to the `Diffusely` and `DiffuselyTests` targets). Same caveat applies to every later task that creates a file.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/LibrarySort.swift DiffuselyTests/LibrarySortTests.swift
git commit -m "Library: add LibrarySort enum (6 cases)"
```

---

## Task 2: Bump sidecar JSON to schema v3 with `publishedAt`

**Files:**
- Modify: `Diffusely/Models/LibraryItemMetadata.swift`
- Modify: `DiffuselyTests/LibraryTests.swift` (the shared `makeMetadata` helper)
- Test: `DiffuselyTests/LibraryTests.swift` (new test cases in `LibraryMetadataTests`)

- [ ] **Step 1: Write the failing tests**

Append to the existing `LibraryMetadataTests` suite in `DiffuselyTests/LibraryTests.swift`:

```swift
    @Test func currentSchemaVersionIsThree() {
        #expect(LibraryItemMetadata.currentSchemaVersion == 3)
    }

    @Test func roundTripsPublishedAt() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let m = makeMetadata(itemID: 400, publishedAt: date)
        let data = try LibraryItemMetadata.encoder().encode(m)
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.publishedAt == date)
    }

    @Test func decodesV2JSONMissingPublishedAtAsNil() throws {
        // A v2 sidecar (post fields present, publishedAt absent) must decode
        // with publishedAt == nil. Adding the new field is a non-breaking
        // optional addition.
        let legacy = """
        {
            "schemaVersion": 2,
            "itemID": 700,
            "sourcePostID": 5,
            "sourcePostTitle": "Old post",
            "canonicalPostURL": "https://civitai.com/posts/5",
            "canonicalPageURL": "https://civitai.com/images/700",
            "sourceDomain": "civitai.com",
            "originalCDNURL": "https://image.civitai.com/x/u/original=true/700.jpeg",
            "mediaType": "image",
            "mediaFileName": "700.jpeg",
            "fileByteSize": 10,
            "contentSHA256": "ab",
            "width": 1, "height": 1, "nsfwLevel": 1,
            "author": {},
            "savedAt": "2026-01-01T00:00:00Z",
            "savedByAppVersion": "old"
        }
        """.data(using: .utf8)!
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: legacy)
        #expect(decoded.itemID == 700)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.publishedAt == nil)
    }
```

Then update the `makeMetadata` helper at the top of `LibraryTests.swift` to take an optional `publishedAt`:

```swift
private func makeMetadata(
    itemID: Int,
    mediaType: LibraryMediaType = .image,
    byteSize: Int = 1000,
    savedAt: Date = Date(),
    generationData: GenerationData? = nil,
    sourcePostTitle: String? = "My Post",
    canonicalPostURL: String? = "https://civitai.com/posts/42",
    publishedAt: Date? = nil
) -> LibraryItemMetadata {
    LibraryItemMetadata(
        schemaVersion: LibraryItemMetadata.currentSchemaVersion,
        itemID: itemID,
        sourcePostID: 42,
        sourcePostTitle: sourcePostTitle,
        canonicalPostURL: canonicalPostURL,
        canonicalPageURL: "https://civitai.com/images/\(itemID)",
        sourceDomain: "civitai.com",
        originalCDNURL: "https://image.civitai.com/x/uuid/original=true/\(itemID).\(mediaType.fileExtension)",
        mediaType: mediaType,
        mediaFileName: "\(itemID).\(mediaType.fileExtension)",
        fileByteSize: byteSize,
        contentSHA256: "deadbeef",
        width: 1024,
        height: 1536,
        nsfwLevel: 1,
        author: LibraryAuthor(id: 7, username: "alice", avatarURL: nil),
        stats: nil,
        generationData: generationData,
        publishedAt: publishedAt,
        savedAt: savedAt,
        savedByAppVersion: "test"
    )
}
```

- [ ] **Step 2: Run tests to verify they fail to compile / fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryMetadataTests`
Expected: build fails — `extra argument 'publishedAt' in call` (helper changed but `LibraryItemMetadata` doesn't have the field yet).

- [ ] **Step 3: Add `publishedAt` to `LibraryItemMetadata` and bump version**

Edit `Diffusely/Models/LibraryItemMetadata.swift`:

```swift
struct LibraryItemMetadata: Codable, Equatable {
    static let currentSchemaVersion = 3   // was 2

    var schemaVersion: Int
    /// Civitai image id. Also the filename stem for both the media and this JSON.
    let itemID: Int
    let sourcePostID: Int?
    /// Title of the source post, if the item belonged to one (best-effort).
    let sourcePostTitle: String?
    /// Canonical Civitai page for the source post, if any.
    let canonicalPostURL: String?
    /// Canonical Civitai page for the item, honoring the domain at save time.
    let canonicalPageURL: String
    /// Domain (civitai.com / civitai.red) selected when the item was saved.
    let sourceDomain: String
    /// Original full-resolution CDN URL the media was downloaded from.
    let originalCDNURL: String
    let mediaType: LibraryMediaType
    let mediaFileName: String
    let fileByteSize: Int
    /// SHA-256 of the media bytes for integrity checks after iCloud transfer.
    let contentSHA256: String
    let width: Int
    let height: Int
    let nsfwLevel: Int
    let author: LibraryAuthor
    let stats: ImageStats?
    let generationData: GenerationData?
    /// Original Civitai publish date. Nullable: absent in v2 sidecars and
    /// when the source image is itself missing it. Backfilled on demand
    /// via `LibraryDateBackfillService`.
    let publishedAt: Date?
    let savedAt: Date
    let savedByAppVersion: String

    static func == (lhs: LibraryItemMetadata, rhs: LibraryItemMetadata) -> Bool {
        lhs.itemID == rhs.itemID
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.contentSHA256 == rhs.contentSHA256
            && lhs.mediaFileName == rhs.mediaFileName
            && lhs.savedAt == rhs.savedAt
            && lhs.publishedAt == rhs.publishedAt
    }
}
```

> The field declaration order matters because `Codable` derives keys from properties. New field goes **after** `generationData` and **before** `savedAt`. Existing v1/v2 sidecars decoded by this struct have a missing key for `publishedAt`, which `Codable` tolerates because the property is optional.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryMetadataTests`
Expected: all `LibraryMetadataTests` tests PASS, including the three new ones.

Also re-run the full `LibraryTests` to confirm nothing else broke (the `makeMetadata` signature change touches many callers):
Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests`
Expected: all existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/LibraryItemMetadata.swift DiffuselyTests/LibraryTests.swift
git commit -m "Library: sidecar schema v3 (add publishedAt)"
```

---

## Task 3: Denormalize new columns onto `PersistedLibraryItem`

**Files:**
- Modify: `Diffusely/Models/Persistence/PersistedLibraryItem.swift`
- Test: `DiffuselyTests/LibrarySortTests.swift` (add `PersistedLibraryItemDenormalizationTests` suite)

- [ ] **Step 1: Write the failing tests**

Append to `DiffuselyTests/LibrarySortTests.swift` (re-declare the same `makeMetadata` helper locally to keep the suite self-contained — file-private to this file):

```swift
private func makeMeta(
    itemID: Int,
    mediaType: LibraryMediaType = .image,
    publishedAt: Date? = nil,
    author: LibraryAuthor = LibraryAuthor(id: 1, username: "alice", avatarURL: "https://x/avatar.png"),
    generationData: GenerationData? = nil
) -> LibraryItemMetadata {
    LibraryItemMetadata(
        schemaVersion: LibraryItemMetadata.currentSchemaVersion,
        itemID: itemID,
        sourcePostID: nil,
        sourcePostTitle: nil,
        canonicalPostURL: nil,
        canonicalPageURL: "https://civitai.com/images/\(itemID)",
        sourceDomain: "civitai.com",
        originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).\(mediaType.fileExtension)",
        mediaType: mediaType,
        mediaFileName: "\(itemID).\(mediaType.fileExtension)",
        fileByteSize: 1,
        contentSHA256: "x",
        width: 1, height: 1, nsfwLevel: 1,
        author: author,
        stats: nil,
        generationData: generationData,
        publishedAt: publishedAt,
        savedAt: Date(),
        savedByAppVersion: "t"
    )
}

private func gen(checkpointModelType: String? = "Checkpoint",
                 checkpointModelName: String? = "DreamShaper",
                 extraResources: [GenerationResource] = []) -> GenerationData {
    var resources: [GenerationResource] = []
    if let checkpointModelType, let checkpointModelName {
        resources.append(GenerationResource(
            modelId: 1, modelName: checkpointModelName, modelType: checkpointModelType,
            versionId: 1, versionName: "v1", strength: 1.0
        ))
    }
    resources.append(contentsOf: extraResources)
    return GenerationData(type: "image", meta: nil, resources: resources)
}

@Suite struct PersistedLibraryItemDenormalizationTests {
    @Test func denormalizesPublishedAtAvatarAndCheckpoint() {
        let pub = Date(timeIntervalSince1970: 1_700_000_000)
        let meta = makeMeta(
            itemID: 42,
            publishedAt: pub,
            author: LibraryAuthor(id: 1, username: "alice", avatarURL: "https://x/avatar.png"),
            generationData: gen(checkpointModelType: "Checkpoint", checkpointModelName: "DreamShaper")
        )
        let row = PersistedLibraryItem(metadata: meta, downloadStatus: .downloaded)
        #expect(row.publishedAt == pub)
        #expect(row.authorAvatarURL == "https://x/avatar.png")
        #expect(row.checkpointName == "DreamShaper")
    }

    @Test func leavesCheckpointNilWhenNoCheckpointResource() {
        let lora = GenerationResource(modelId: 9, modelName: "SomeLora", modelType: "LORA",
                                      versionId: 1, versionName: "v1", strength: 0.5)
        let meta = makeMeta(
            itemID: 43,
            generationData: GenerationData(type: "image", meta: nil, resources: [lora])
        )
        let row = PersistedLibraryItem(metadata: meta, downloadStatus: .downloaded)
        #expect(row.checkpointName == nil)
    }

    @Test func picksFirstCheckpointResourceWhenMultiple() {
        let first = GenerationResource(modelId: 1, modelName: "Alpha",
                                       modelType: "Checkpoint", versionId: 1, versionName: "v1", strength: 1)
        let second = GenerationResource(modelId: 2, modelName: "Beta",
                                        modelType: "Checkpoint", versionId: 2, versionName: "v1", strength: 1)
        let meta = makeMeta(
            itemID: 44,
            generationData: GenerationData(type: "image", meta: nil, resources: [first, second])
        )
        let row = PersistedLibraryItem(metadata: meta, downloadStatus: .downloaded)
        #expect(row.checkpointName == "Alpha")
    }

    @Test func leavesEverythingNilWhenMetadataIsSparse() {
        let meta = makeMeta(
            itemID: 45,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            generationData: nil
        )
        let row = PersistedLibraryItem(metadata: meta, downloadStatus: .downloaded)
        #expect(row.publishedAt == nil)
        #expect(row.authorAvatarURL == nil)
        #expect(row.checkpointName == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/PersistedLibraryItemDenormalizationTests`
Expected: build fails — `value of type 'PersistedLibraryItem' has no member 'publishedAt'` (etc.).

- [ ] **Step 3: Add the three columns + denormalization**

Edit `Diffusely/Models/Persistence/PersistedLibraryItem.swift`:

```swift
@Model
final class PersistedLibraryItem {
    @Attribute(.unique) var itemID: Int
    var mediaType: String          // "image" | "video"
    var mediaFileName: String
    var width: Int
    var height: Int
    var nsfwLevel: Int
    var authorUsername: String?
    /// Avatar URL denormalized from the sidecar's LibraryAuthor.avatarURL.
    /// Drives author-grouped section headers; rebuilt by reconcile.
    var authorAvatarURL: String?
    var sourcePostID: Int?
    var canonicalPageURL: String
    var fileByteSize: Int
    var savedAt: Date
    /// Original Civitai publish date (denormalized from sidecar). Nullable
    /// for items predating schema v3; backfilled on demand.
    var publishedAt: Date?
    /// First `Checkpoint`-typed resource in the sidecar's generationData.
    /// Nullable when generation data is missing or has no checkpoint
    /// (typical for videos and bare uploads).
    var checkpointName: String?
    var lastAccessedAt: Date
    var downloadStatusRaw: String

    init(
        itemID: Int,
        mediaType: String,
        mediaFileName: String,
        width: Int,
        height: Int,
        nsfwLevel: Int,
        authorUsername: String?,
        authorAvatarURL: String?,
        sourcePostID: Int?,
        canonicalPageURL: String,
        fileByteSize: Int,
        savedAt: Date,
        publishedAt: Date?,
        checkpointName: String?,
        lastAccessedAt: Date,
        downloadStatus: LibraryDownloadStatus
    ) {
        self.itemID = itemID
        self.mediaType = mediaType
        self.mediaFileName = mediaFileName
        self.width = width
        self.height = height
        self.nsfwLevel = nsfwLevel
        self.authorUsername = authorUsername
        self.authorAvatarURL = authorAvatarURL
        self.sourcePostID = sourcePostID
        self.canonicalPageURL = canonicalPageURL
        self.fileByteSize = fileByteSize
        self.savedAt = savedAt
        self.publishedAt = publishedAt
        self.checkpointName = checkpointName
        self.lastAccessedAt = lastAccessedAt
        self.downloadStatusRaw = downloadStatus.rawValue
    }

    convenience init(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
        let checkpoint = metadata.generationData?
            .resources?
            .first(where: { $0.modelType == "Checkpoint" })?
            .modelName
        self.init(
            itemID: metadata.itemID,
            mediaType: metadata.mediaType.rawValue,
            mediaFileName: metadata.mediaFileName,
            width: metadata.width,
            height: metadata.height,
            nsfwLevel: metadata.nsfwLevel,
            authorUsername: metadata.author.username,
            authorAvatarURL: metadata.author.avatarURL,
            sourcePostID: metadata.sourcePostID,
            canonicalPageURL: metadata.canonicalPageURL,
            fileByteSize: metadata.fileByteSize,
            savedAt: metadata.savedAt,
            publishedAt: metadata.publishedAt,
            checkpointName: checkpoint,
            lastAccessedAt: metadata.savedAt,
            downloadStatus: downloadStatus
        )
    }

    var downloadStatus: LibraryDownloadStatus {
        get { LibraryDownloadStatus(rawValue: downloadStatusRaw) ?? .downloaded }
        set { downloadStatusRaw = newValue.rawValue }
    }

    var isVideo: Bool { mediaType == LibraryMediaType.video.rawValue }
}
```

> SwiftData picks up the three new optional properties as nullable columns automatically. Because the index is disposable (rebuilt by `LibraryIndexService.reconcile`) there is no separate migration to write. The next reconcile run re-derives all three columns from the sidecars.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/PersistedLibraryItemDenormalizationTests`
Expected: all 4 tests PASS.

Run the full library test target to catch fallout from the new init signature:
Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests`
Expected: all tests PASS. (The designated init now has new required parameters; any direct callers of `PersistedLibraryItem(...)` need updating — currently there are none outside `init(metadata:)`. If any appear, update them with `authorAvatarURL: nil, publishedAt: nil, checkpointName: nil`.)

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/Persistence/PersistedLibraryItem.swift DiffuselyTests/LibrarySortTests.swift
git commit -m "Library: denormalize publishedAt / avatar / checkpoint onto index"
```

---

## Task 4: `LibraryIndexService.ingest` updates new columns on the "existing" branch

**Files:**
- Modify: `Diffusely/Services/LibraryIndexService.swift:13-31`
- Test: `DiffuselyTests/LibrarySortTests.swift` (add `LibraryIndexIngestTests` suite)

- [ ] **Step 1: Write the failing test**

Append to `DiffuselyTests/LibrarySortTests.swift`:

```swift
import SwiftData

@Suite struct LibraryIndexIngestTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @Test func reIngestUpdatesPublishedAtAvatarAndCheckpoint() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        // Initial ingest: no publish date, no avatar, no checkpoint.
        let initial = makeMeta(
            itemID: 99,
            publishedAt: nil,
            author: LibraryAuthor(id: 1, username: "alice", avatarURL: nil),
            generationData: nil
        )
        await index.ingest(metadata: initial, downloadStatus: .downloaded)

        // Re-ingest with backfilled values.
        let backfilled = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = makeMeta(
            itemID: 99,
            publishedAt: backfilled,
            author: LibraryAuthor(id: 1, username: "alice", avatarURL: "https://x/a.png"),
            generationData: gen(checkpointModelName: "Realistic")
        )
        await index.ingest(metadata: updated, downloadStatus: .downloaded)

        let row = try await MainActor.run { () -> PersistedLibraryItem? in
            var d = FetchDescriptor<PersistedLibraryItem>(predicate: #Predicate { $0.itemID == 99 })
            d.fetchLimit = 1
            return try container.mainContext.fetch(d).first
        }
        #expect(row?.publishedAt == backfilled)
        #expect(row?.authorAvatarURL == "https://x/a.png")
        #expect(row?.checkpointName == "Realistic")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryIndexIngestTests`
Expected: FAIL — the existing-row branch of `ingest` does not assign the new fields, so re-ingest leaves them at their initial values.

- [ ] **Step 3: Update the "existing" branch of `ingest`**

Edit the body of `func ingest(metadata:downloadStatus:)` in `Diffusely/Services/LibraryIndexService.swift`:

```swift
func ingest(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
    let id = metadata.itemID
    if let existing = fetchItem(itemID: id) {
        existing.mediaType = metadata.mediaType.rawValue
        existing.mediaFileName = metadata.mediaFileName
        existing.width = metadata.width
        existing.height = metadata.height
        existing.nsfwLevel = metadata.nsfwLevel
        existing.authorUsername = metadata.author.username
        existing.authorAvatarURL = metadata.author.avatarURL
        existing.sourcePostID = metadata.sourcePostID
        existing.canonicalPageURL = metadata.canonicalPageURL
        existing.fileByteSize = metadata.fileByteSize
        existing.savedAt = metadata.savedAt
        existing.publishedAt = metadata.publishedAt
        existing.checkpointName = metadata.generationData?
            .resources?
            .first(where: { $0.modelType == "Checkpoint" })?
            .modelName
        existing.downloadStatus = downloadStatus
    } else {
        modelContext.insert(PersistedLibraryItem(metadata: metadata, downloadStatus: downloadStatus))
    }
    try? modelContext.save()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryIndexIngestTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/LibraryIndexService.swift DiffuselyTests/LibrarySortTests.swift
git commit -m "Library: ingest updates new columns on existing rows"
```

---

## Task 5: `LibrarySaveService` writes `publishedAt` to the sidecar

**Files:**
- Modify: `Diffusely/Services/LibrarySaveService.swift:201-222`

- [ ] **Step 1: Locate the `LibraryItemMetadata(...)` call**

In `performSave`, around line 201, the metadata is constructed from the live `CivitaiImage`. The image has `publishedAtDate: Date?`.

- [ ] **Step 2: Pass `publishedAt` through**

Edit the metadata construction to include the new field. The block becomes:

```swift
let metadata = LibraryItemMetadata(
    schemaVersion: LibraryItemMetadata.currentSchemaVersion,
    itemID: itemID,
    sourcePostID: image.postId,
    sourcePostTitle: postTitle,
    canonicalPostURL: canonicalPostURL,
    canonicalPageURL: canonicalPageURL,
    sourceDomain: sourceDomain,
    originalCDNURL: originalCDNURL,
    mediaType: mediaType,
    mediaFileName: "\(itemID).\(mediaType.fileExtension)",
    fileByteSize: byteSize,
    contentSHA256: sha,
    width: image.width,
    height: image.height,
    nsfwLevel: image.nsfwLevel,
    author: author,
    stats: image.stats,
    generationData: generationData,
    publishedAt: image.publishedAtDate,
    savedAt: Date(),
    savedByAppVersion: Self.appVersion
)
```

- [ ] **Step 3: Build to verify the call compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full test suite to confirm nothing regressed**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/LibrarySaveService.swift
git commit -m "Library: capture publishedAt on save"
```

---

## Task 6: `LibrarySortService` — sorted-content and missing-date count

**Files:**
- Create: `Diffusely/Services/LibrarySortService.swift`
- Test: `DiffuselyTests/LibrarySortTests.swift` (add `LibrarySortServiceTests` suite)

- [ ] **Step 1: Write the failing tests**

Append to `DiffuselyTests/LibrarySortTests.swift`:

```swift
@Suite struct LibrarySortServiceTests {
    @MainActor
    private func makeService() throws -> (LibrarySortService, ModelContext) {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let ctx = container.mainContext
        return (LibrarySortService(modelContext: ctx), ctx)
    }

    @MainActor
    private func insert(
        _ ctx: ModelContext,
        id: Int,
        publishedAt: Date?,
        author: String?,
        avatar: String? = nil,
        checkpoint: String? = nil,
        mediaType: LibraryMediaType = .image
    ) {
        let row = PersistedLibraryItem(
            itemID: id,
            mediaType: mediaType.rawValue,
            mediaFileName: "\(id).\(mediaType.fileExtension)",
            width: 1, height: 1, nsfwLevel: 1,
            authorUsername: author,
            authorAvatarURL: avatar,
            sourcePostID: nil,
            canonicalPageURL: "https://civitai.com/images/\(id)",
            fileByteSize: 1,
            savedAt: Date(),
            publishedAt: publishedAt,
            checkpointName: checkpoint,
            lastAccessedAt: Date(),
            downloadStatus: .downloaded
        )
        ctx.insert(row)
    }

    @MainActor
    @Test func dateNewestPutsLatestFirstAndNilDatesLast() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now.addingTimeInterval(-100), author: "a")
        insert(ctx, id: 2, publishedAt: now,                           author: "b")
        insert(ctx, id: 3, publishedAt: nil,                           author: "c")

        guard case .flat(let items) = svc.sortedLibraryContent(sort: .dateNewest) else {
            Issue.record("expected flat"); return
        }
        #expect(items.map { $0.itemID } == [2, 1, 3])
    }

    @MainActor
    @Test func dateOldestPutsEarliestFirstAndNilDatesStillLast() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now.addingTimeInterval(-100), author: "a")
        insert(ctx, id: 2, publishedAt: now,                           author: "b")
        insert(ctx, id: 3, publishedAt: nil,                           author: "c")

        guard case .flat(let items) = svc.sortedLibraryContent(sort: .dateOldest) else {
            Issue.record("expected flat"); return
        }
        #expect(items.map { $0.itemID } == [1, 2, 3])
    }

    @MainActor
    @Test func authorAscendingGroupsCaseInsensitivelyAndUnknownTrailingBoth() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now, author: "Bob")
        insert(ctx, id: 2, publishedAt: now, author: "alice")
        insert(ctx, id: 3, publishedAt: now, author: "Alice")
        insert(ctx, id: 4, publishedAt: now, author: nil)

        guard case .grouped(let groups) = svc.sortedLibraryContent(sort: .authorAscending) else {
            Issue.record("expected grouped"); return
        }
        // Alice (case-insensitive collapse) first, then Bob, then Unknown.
        #expect(groups.count == 3)
        if case .author(let username, _) = groups[0].kind { #expect(username.lowercased() == "alice") }
        if case .author(let username, _) = groups[1].kind { #expect(username == "Bob") }
        if case .bucket(let b) = groups[2].kind { #expect(b == .unknownAuthor) }
        // Items inside the merged Alice group: both ids present, newest-first
        // (here by itemID tie-break since publishedAt is identical).
        #expect(Set(groups[0].items.map { $0.itemID }) == [2, 3])
    }

    @MainActor
    @Test func authorDescendingReversesSectionsButKeepsUnknownAtTail() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now, author: "Bob")
        insert(ctx, id: 2, publishedAt: now, author: "Alice")
        insert(ctx, id: 3, publishedAt: now, author: nil)

        guard case .grouped(let groups) = svc.sortedLibraryContent(sort: .authorDescending) else {
            Issue.record("expected grouped"); return
        }
        #expect(groups.count == 3)
        if case .author(let u, _) = groups[0].kind { #expect(u == "Bob") }
        if case .author(let u, _) = groups[1].kind { #expect(u == "Alice") }
        if case .bucket(let b) = groups[2].kind { #expect(b == .unknownAuthor) }
    }

    @MainActor
    @Test func checkpointAscendingPutsBucketsAtTailVideosBeforeOther() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now, author: "a", checkpoint: "Realistic")
        insert(ctx, id: 2, publishedAt: now, author: "a", checkpoint: "Anime")
        insert(ctx, id: 3, publishedAt: now, author: "a", checkpoint: nil)                       // image w/o ckpt -> Other
        insert(ctx, id: 4, publishedAt: now, author: "a", checkpoint: nil, mediaType: .video)    // video -> Videos

        guard case .grouped(let groups) = svc.sortedLibraryContent(sort: .checkpointAscending) else {
            Issue.record("expected grouped"); return
        }
        #expect(groups.count == 4)
        if case .checkpoint(let n) = groups[0].kind { #expect(n == "Anime") }
        if case .checkpoint(let n) = groups[1].kind { #expect(n == "Realistic") }
        if case .bucket(let b) = groups[2].kind { #expect(b == .videos) }
        if case .bucket(let b) = groups[3].kind { #expect(b == .other) }
    }

    @MainActor
    @Test func checkpointDescendingReversesNamedButKeepsBucketsAtTailInFixedOrder() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now, author: "a", checkpoint: "Realistic")
        insert(ctx, id: 2, publishedAt: now, author: "a", checkpoint: "Anime")
        insert(ctx, id: 3, publishedAt: now, author: "a", checkpoint: nil)
        insert(ctx, id: 4, publishedAt: now, author: "a", checkpoint: nil, mediaType: .video)

        guard case .grouped(let groups) = svc.sortedLibraryContent(sort: .checkpointDescending) else {
            Issue.record("expected grouped"); return
        }
        if case .checkpoint(let n) = groups[0].kind { #expect(n == "Realistic") }
        if case .checkpoint(let n) = groups[1].kind { #expect(n == "Anime") }
        if case .bucket(let b) = groups[2].kind { #expect(b == .videos) }
        if case .bucket(let b) = groups[3].kind { #expect(b == .other) }
    }

    @MainActor
    @Test func withinGroupItemsAreNewestFirstRegardlessOfOuterDirection() throws {
        let (svc, ctx) = try makeService()
        let now = Date()
        insert(ctx, id: 1, publishedAt: now.addingTimeInterval(-100), author: "alice", checkpoint: "Realistic")
        insert(ctx, id: 2, publishedAt: now,                           author: "alice", checkpoint: "Realistic")

        for sort in [LibrarySort.authorAscending, .authorDescending, .checkpointAscending, .checkpointDescending] {
            guard case .grouped(let groups) = svc.sortedLibraryContent(sort: sort),
                  let first = groups.first else {
                Issue.record("expected grouped for \(sort.rawValue)"); continue
            }
            #expect(first.items.map { $0.itemID } == [2, 1], "wrong within-group order for \(sort.rawValue)")
        }
    }

    @MainActor
    @Test func countItemsMissingPublishedDateCountsOnlyNils() throws {
        let (svc, ctx) = try makeService()
        insert(ctx, id: 1, publishedAt: Date(), author: "a")
        insert(ctx, id: 2, publishedAt: nil,    author: "a")
        insert(ctx, id: 3, publishedAt: nil,    author: "b")
        #expect(svc.countItemsMissingPublishedDate() == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySortServiceTests`
Expected: build fails — `cannot find 'LibrarySortService'`.

- [ ] **Step 3: Create the service**

Create `Diffusely/Services/LibrarySortService.swift`:

```swift
import Foundation
import SwiftData

/// Read-side helper for `LibraryView`. Lives on the main actor because it
/// returns `PersistedLibraryItem` rows owned by the main `ModelContext` and
/// the view consumes them directly. Writes still go through
/// `LibraryIndexService`; this type never mutates.
@MainActor
final class LibrarySortService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Result types

    /// Either a flat ordered list (date sorts) or grouped sections
    /// (author / checkpoint sorts). Mirrors
    /// `CollectionPersistenceService.SortedCollectionContent`.
    enum LibrarySortedContent: Equatable {
        case flat([PersistedLibraryItem])
        case grouped([LibraryGroup])

        var isEmpty: Bool {
            switch self {
            case .flat(let items):    return items.isEmpty
            case .grouped(let groups): return groups.isEmpty
            }
        }
    }

    struct LibraryGroup: Identifiable, Equatable {
        enum Kind: Equatable {
            case author(username: String, avatarURL: String?)
            case checkpoint(name: String)
            case bucket(Bucket)
        }
        enum Bucket: Equatable {
            case videos          // checkpoint sort: items with no checkpoint and type == video
            case other           // checkpoint sort: items with no checkpoint and type == image
            case unknownAuthor   // author sort: items with no authorUsername
        }
        let id: String
        let kind: Kind
        let items: [PersistedLibraryItem]
    }

    // MARK: - Public API

    func sortedLibraryContent(sort: LibrarySort) -> LibrarySortedContent {
        let all = fetchAll()
        switch sort {
        case .dateNewest, .dateOldest:
            return .flat(sortByDate(all, ascending: sort.ascending))
        case .authorAscending, .authorDescending:
            return .grouped(groupByAuthor(all, ascending: sort.ascending))
        case .checkpointAscending, .checkpointDescending:
            return .grouped(groupByCheckpoint(all, ascending: sort.ascending))
        }
    }

    func countItemsMissingPublishedDate() -> Int {
        let descriptor = FetchDescriptor<PersistedLibraryItem>(
            predicate: #Predicate { $0.publishedAt == nil }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Internals

    private func fetchAll() -> [PersistedLibraryItem] {
        (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
    }

    /// Newest-first when `ascending == false`. Items with `publishedAt == nil`
    /// sink to the tail in both directions; ties (including the nil bucket)
    /// break by `itemID` descending for stability.
    private func sortByDate(_ items: [PersistedLibraryItem], ascending: Bool) -> [PersistedLibraryItem] {
        items.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (a?, b?):
                if a == b { return lhs.itemID > rhs.itemID }
                return ascending ? a < b : a > b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.itemID > rhs.itemID
            }
        }
    }

    /// Same nil-sink + id-descending tie-break used for flat date sorts, but
    /// always newest-first (used inside groups).
    private func newestFirst(_ items: [PersistedLibraryItem]) -> [PersistedLibraryItem] {
        sortByDate(items, ascending: false)
    }

    private func groupByAuthor(
        _ items: [PersistedLibraryItem],
        ascending: Bool
    ) -> [LibraryGroup] {
        // Bucket by lowercased username; items with no username go to a single
        // "Unknown" group placed at the tail regardless of direction.
        var named: [String: (display: String, avatar: String?, items: [PersistedLibraryItem])] = [:]
        var unknown: [PersistedLibraryItem] = []

        for item in items {
            guard let username = item.authorUsername, !username.isEmpty else {
                unknown.append(item)
                continue
            }
            let key = username.lowercased()
            if var entry = named[key] {
                entry.items.append(item)
                if entry.avatar == nil { entry.avatar = item.authorAvatarURL }
                named[key] = entry
            } else {
                named[key] = (display: username, avatar: item.authorAvatarURL, items: [item])
            }
        }

        var groups: [LibraryGroup] = named
            .map { key, entry in
                LibraryGroup(
                    id: "author:\(key)",
                    kind: .author(username: entry.display, avatarURL: entry.avatar),
                    items: newestFirst(entry.items)
                )
            }
            .sorted { lhs, rhs in
                let l = displayName(lhs).lowercased()
                let r = displayName(rhs).lowercased()
                return ascending ? l < r : l > r
            }

        if !unknown.isEmpty {
            groups.append(LibraryGroup(
                id: "author:__unknown__",
                kind: .bucket(.unknownAuthor),
                items: newestFirst(unknown)
            ))
        }
        return groups
    }

    private func groupByCheckpoint(
        _ items: [PersistedLibraryItem],
        ascending: Bool
    ) -> [LibraryGroup] {
        var named: [String: [PersistedLibraryItem]] = [:]
        var videos: [PersistedLibraryItem] = []
        var other: [PersistedLibraryItem] = []

        for item in items {
            if let name = item.checkpointName, !name.isEmpty {
                named[name, default: []].append(item)
            } else if item.isVideo {
                videos.append(item)
            } else {
                other.append(item)
            }
        }

        var groups: [LibraryGroup] = named
            .map { name, list in
                LibraryGroup(
                    id: "checkpoint:\(name)",
                    kind: .checkpoint(name: name),
                    items: newestFirst(list)
                )
            }
            .sorted { lhs, rhs in
                let l = displayName(lhs).lowercased()
                let r = displayName(rhs).lowercased()
                return ascending ? l < r : l > r
            }

        if !videos.isEmpty {
            groups.append(LibraryGroup(
                id: "bucket:videos",
                kind: .bucket(.videos),
                items: newestFirst(videos)
            ))
        }
        if !other.isEmpty {
            groups.append(LibraryGroup(
                id: "bucket:other",
                kind: .bucket(.other),
                items: newestFirst(other)
            ))
        }
        return groups
    }

    private func displayName(_ group: LibraryGroup) -> String {
        switch group.kind {
        case .author(let username, _): return username
        case .checkpoint(let name):     return name
        case .bucket(.videos):          return "Videos"
        case .bucket(.other):           return "Other"
        case .bucket(.unknownAuthor):   return "Unknown"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibrarySortServiceTests`
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/LibrarySortService.swift DiffuselyTests/LibrarySortTests.swift
git commit -m "Library: add LibrarySortService"
```

---

## Task 7: `CivitaiService.fetchImage(imageId:)`

**Files:**
- Modify: `Diffusely/Services/CivitaiService.swift` — add `fetchImage(imageId:)` near `fetchGenerationData(imageId:)` (around line 318).

No automated test — the file's other tRPC methods (`fetchGenerationData`, `fetchImagesPage`) have no test coverage either; they're exercised via integration. This task is a small surgical addition.

- [ ] **Step 1: Add the method**

After `fetchGenerationData(imageId:)` in `Diffusely/Services/CivitaiService.swift`, add:

```swift
/// Fetches a single image by id via `/api/trpc/image.get`. Used by
/// `LibraryDateBackfillService` to retrieve `publishedAt` for library items
/// saved before sidecar schema v3.
func fetchImage(imageId: Int) async throws -> CivitaiImage {
    var components = URLComponents(string: "\(baseURL)/image.get")!

    let inputParams: [String: Any] = [
        "id": imageId
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
    let (data, _) = try await session.data(for: request)

    // image.get returns a single image object (not an array), mirroring
    // image.getGenerationData's response shape.
    struct SingleResponse: Codable {
        let result: SingleResult
    }
    struct SingleResult: Codable {
        let data: SingleData
    }
    struct SingleData: Codable {
        let json: CivitaiImage
    }

    let tRPCResponse = try JSONDecoder().decode([SingleResponse].self, from: data)
    return tRPCResponse[0].result.data.json
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Services/CivitaiService.swift
git commit -m "CivitaiService: add fetchImage(imageId:) wrapping image.get"
```

---

## Task 8: `LibraryFileWriter.rewriteMetadata` helper

**Files:**
- Modify: `Diffusely/Services/LibrarySaveService.swift:21-81` (the `LibraryFileWriter` struct)
- Test: `DiffuselyTests/LibraryTests.swift` (extend `LibraryFileWriterTests`)

- [ ] **Step 1: Write the failing test**

Append to `LibraryFileWriterTests` in `DiffuselyTests/LibraryTests.swift`:

```swift
    @Test func rewriteMetadataReplacesJSONInPlace() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LibraryFileWriter(itemsDirectory: dir)

        // Commit an initial item with no publishedAt.
        let initial = makeMetadata(itemID: 600, publishedAt: nil)
        let tempMedia = dir.appendingPathComponent("download.tmp")
        try Data("bytes".utf8).write(to: tempMedia)
        try writer.commit(metadata: initial, mediaTempURL: tempMedia)

        // Rewrite with a publishedAt.
        let pub = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = makeMetadata(itemID: 600, publishedAt: pub)
        try writer.rewriteMetadata(updated)

        let json = try Data(contentsOf: dir.appendingPathComponent("600.json"))
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: json)
        #expect(decoded.itemID == 600)
        #expect(decoded.publishedAt == pub)
        // Media file untouched.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("600.jpeg").path))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileWriterTests`
Expected: FAIL — `value of type 'LibraryFileWriter' has no member 'rewriteMetadata'`.

- [ ] **Step 3: Add the method**

In `Diffusely/Services/LibrarySaveService.swift`, inside the `LibraryFileWriter` struct (after `commit(...)`), add:

```swift
/// Atomically rewrites the sidecar JSON for an already-committed item.
/// Used by `LibraryDateBackfillService` to add fields (like `publishedAt`)
/// onto old sidecars without touching the media file.
func rewriteMetadata(_ metadata: LibraryItemMetadata) throws {
    let json = try LibraryItemMetadata.encoder().encode(metadata)
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var thrown: Error?
    let target = metadataURL(forItemID: metadata.itemID)

    coordinator.coordinate(
        writingItemAt: target,
        options: .forReplacing,
        error: &coordinationError
    ) { destination in
        do {
            try json.write(to: destination, options: .atomic)
        } catch {
            thrown = error
        }
    }
    if let coordinationError { throw coordinationError }
    if let thrown { throw thrown }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileWriterTests`
Expected: all `LibraryFileWriterTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/LibrarySaveService.swift DiffuselyTests/LibraryTests.swift
git commit -m "LibraryFileWriter: add rewriteMetadata for sidecar-only updates"
```

---

## Task 9: `LibraryDateBackfillService`

**Files:**
- Create: `Diffusely/Services/LibraryDateBackfillService.swift`
- Create: `DiffuselyTests/LibraryDateBackfillTests.swift`

The service runs serial (one item at a time) so we can model it with a tiny `FetchImageProvider` protocol the tests stub out.

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryDateBackfillTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

// Local helper duplicates the LibrarySortTests `makeMeta` to keep this file
// self-contained.
private func makeMeta(
    itemID: Int,
    mediaType: LibraryMediaType = .image,
    publishedAt: Date? = nil
) -> LibraryItemMetadata {
    LibraryItemMetadata(
        schemaVersion: LibraryItemMetadata.currentSchemaVersion,
        itemID: itemID,
        sourcePostID: nil,
        sourcePostTitle: nil,
        canonicalPostURL: nil,
        canonicalPageURL: "https://civitai.com/images/\(itemID)",
        sourceDomain: "civitai.com",
        originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).\(mediaType.fileExtension)",
        mediaType: mediaType,
        mediaFileName: "\(itemID).\(mediaType.fileExtension)",
        fileByteSize: 1,
        contentSHA256: "x",
        width: 1, height: 1, nsfwLevel: 1,
        author: LibraryAuthor(id: 1, username: "alice", avatarURL: nil),
        stats: nil,
        generationData: nil,
        publishedAt: publishedAt,
        savedAt: Date(),
        savedByAppVersion: "t"
    )
}

private final class StubFetchImageProvider: LibraryDateBackfillService.FetchImageProvider {
    var responses: [Int: CivitaiImage] = [:]
    var requestedIDs: [Int] = []
    var errorForID: Set<Int> = []
    func fetchImage(imageId: Int) async throws -> CivitaiImage {
        requestedIDs.append(imageId)
        if errorForID.contains(imageId) {
            throw URLError(.notConnectedToInternet)
        }
        guard let img = responses[imageId] else { throw URLError(.cannotFindHost) }
        return img
    }
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func civitaiImage(id: Int, publishedAtISO: String?) -> CivitaiImage {
    CivitaiImage(
        id: id,
        url: "uuid-\(id)",
        width: 1, height: 1, nsfwLevel: 1,
        type: "image",
        postId: nil,
        user: nil,
        stats: nil,
        thumbnailUrl: nil,
        publishedAt: publishedAtISO
    )
}

@Suite struct LibraryDateBackfillTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @Test func backfillRewritesSidecarsAndUpdatesIndexRows() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two items, both missing publishedAt, plus media files.
        for id in [10, 11] {
            let m = makeMeta(itemID: id, publishedAt: nil)
            try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("\(id).json"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        stub.responses[10] = civitaiImage(id: 10, publishedAtISO: "2024-03-22T10:52:00.000Z")
        stub.responses[11] = civitaiImage(id: 11, publishedAtISO: "2024-03-23T11:00:00.000Z")

        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        #expect(Set(stub.requestedIDs) == [10, 11])

        // Sidecars rewritten with publishedAt.
        for id in [10, 11] {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(id).json"))
            let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            #expect(decoded.publishedAt != nil)
        }

        // Index rows updated.
        let rows = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(rows.allSatisfy { $0.publishedAt != nil })
    }

    @Test func backfillSkipsItemsThatAlreadyHavePublishedAt() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let already = Date(timeIntervalSince1970: 1_700_000_000)
        let m = makeMeta(itemID: 20, publishedAt: already)
        try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("20.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("20.jpeg"))

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        #expect(stub.requestedIDs.isEmpty)
    }

    @Test func backfillContinuesPastTransientFailure() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for id in [30, 31] {
            let m = makeMeta(itemID: id, publishedAt: nil)
            try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("\(id).json"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let stub = StubFetchImageProvider()
        stub.errorForID = [30]
        stub.responses[31] = civitaiImage(id: 31, publishedAtISO: "2024-03-23T11:00:00.000Z")

        let svc = await LibraryDateBackfillService(
            indexService: index,
            itemsDirectory: dir,
            fetcher: stub
        )
        await svc.runOnce()

        // Both attempted; only 31 succeeded.
        #expect(Set(stub.requestedIDs) == [30, 31])

        let data31 = try Data(contentsOf: dir.appendingPathComponent("31.json"))
        let decoded31 = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data31)
        #expect(decoded31.publishedAt != nil)

        let data30 = try Data(contentsOf: dir.appendingPathComponent("30.json"))
        let decoded30 = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data30)
        #expect(decoded30.publishedAt == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryDateBackfillTests`
Expected: build fails — `cannot find 'LibraryDateBackfillService'`.

- [ ] **Step 3: Create the service**

Create `Diffusely/Services/LibraryDateBackfillService.swift`:

```swift
import Foundation
import SwiftData

/// One-shot serial backfill: for every sidecar with no `publishedAt`,
/// re-fetch the image from Civitai, rewrite the JSON in place, and update
/// the corresponding index row. Failures are swallowed per-item so a
/// network hiccup on one image doesn't stop the rest of the queue.
///
/// Designed for view-driven on-demand triggering (mirrors how
/// `CollectionDetailView` runs its own date-backfill exactly once per view
/// instance). `@MainActor` so it can be observed by SwiftUI for the
/// "Backfilling publish dates… N remaining" indicator.
@MainActor
final class LibraryDateBackfillService: ObservableObject {

    /// Test seam so we don't need a live `CivitaiService` in unit tests.
    protocol FetchImageProvider: AnyObject {
        func fetchImage(imageId: Int) async throws -> CivitaiImage
    }

    @Published private(set) var remaining: Int = 0
    @Published private(set) var isRunning: Bool = false

    private let indexService: LibraryIndexService
    private let itemsDirectory: URL
    private let fetcher: FetchImageProvider

    init(
        indexService: LibraryIndexService,
        itemsDirectory: URL,
        fetcher: FetchImageProvider
    ) {
        self.indexService = indexService
        self.itemsDirectory = itemsDirectory
        self.fetcher = fetcher
    }

    /// Walk the sidecar directory once, backfill every item whose JSON has
    /// no `publishedAt`. Idempotent: re-running with everything already
    /// backfilled is a no-op.
    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let writer = LibraryFileWriter(itemsDirectory: itemsDirectory)
        let pending = enumeratePendingItems()
        remaining = pending.count

        for metadata in pending {
            defer { remaining = max(0, remaining - 1) }

            do {
                let image = try await fetcher.fetchImage(imageId: metadata.itemID)
                guard let publishedAt = image.publishedAtDate else { continue }

                let updated = LibraryItemMetadata(
                    schemaVersion: LibraryItemMetadata.currentSchemaVersion,
                    itemID: metadata.itemID,
                    sourcePostID: metadata.sourcePostID,
                    sourcePostTitle: metadata.sourcePostTitle,
                    canonicalPostURL: metadata.canonicalPostURL,
                    canonicalPageURL: metadata.canonicalPageURL,
                    sourceDomain: metadata.sourceDomain,
                    originalCDNURL: metadata.originalCDNURL,
                    mediaType: metadata.mediaType,
                    mediaFileName: metadata.mediaFileName,
                    fileByteSize: metadata.fileByteSize,
                    contentSHA256: metadata.contentSHA256,
                    width: metadata.width,
                    height: metadata.height,
                    nsfwLevel: metadata.nsfwLevel,
                    author: metadata.author,
                    stats: image.stats ?? metadata.stats,
                    generationData: metadata.generationData,
                    publishedAt: publishedAt,
                    savedAt: metadata.savedAt,
                    savedByAppVersion: metadata.savedByAppVersion
                )

                try writer.rewriteMetadata(updated)
                let status = await indexService.currentDownloadStatus(itemID: metadata.itemID) ?? .downloaded
                await indexService.ingest(metadata: updated, downloadStatus: status)
            } catch {
                // Per-item failure: leave publishedAt nil and move on.
                continue
            }
        }
    }

    /// Read every sidecar JSON in the directory and return those missing
    /// `publishedAt`. This is the source of truth; the index is just a cache.
    private func enumeratePendingItems() -> [LibraryItemMetadata] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil)) ?? []
        var pending: [LibraryItemMetadata] = []
        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data),
                metadata.publishedAt == nil
            else { continue }
            pending.append(metadata)
        }
        return pending
    }
}
```

Now add the small `currentDownloadStatus(itemID:)` helper to `LibraryIndexService` so the backfill can preserve the existing status when re-ingesting. In `Diffusely/Services/LibraryIndexService.swift`, add near `setStatus`:

```swift
func currentDownloadStatus(itemID: Int) -> LibraryDownloadStatus? {
    fetchItem(itemID: itemID)?.downloadStatus
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryDateBackfillTests`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/LibraryDateBackfillService.swift Diffusely/Services/LibraryIndexService.swift DiffuselyTests/LibraryDateBackfillTests.swift
git commit -m "Library: add LibraryDateBackfillService"
```

---

## Task 10: `LibrarySortMenu` view

**Files:**
- Create: `Diffusely/Views/LibrarySortMenu.swift`

This view has no unit tests — it's a straight port of `CollectionSortMenu`'s structure. We verify by build + visual smoke in Task 12.

- [ ] **Step 1: Create the view**

Create `Diffusely/Views/LibrarySortMenu.swift`:

```swift
import SwiftUI

/// Toolbar `Menu` for selecting a `LibrarySort`. Mirrors `CollectionSortMenu`
/// case-for-case so the affordance feels the same across the two screens.
struct LibrarySortMenu: View {
    @Binding var selectedSort: LibrarySort

    var body: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
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
        } label: {
            #if os(macOS)
            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
            #else
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.primary)
            #endif
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/LibrarySortMenu.swift
git commit -m "Library: add LibrarySortMenu"
```

---

## Task 11: `LibraryGroupHeader` view

**Files:**
- Create: `Diffusely/Views/LibraryGroupHeader.swift`

Used for checkpoint and bucket groups. Author groups continue to use the existing `AuthorSectionHeader` (with a synthesized `CivitaiUser`).

- [ ] **Step 1: Create the view**

Create `Diffusely/Views/LibraryGroupHeader.swift`:

```swift
import SwiftUI

/// Pinned section header for library groups that aren't backed by an author.
/// Visual shape mirrors `AuthorSectionHeader` so the two read consistently.
struct LibraryGroupHeader: View {
    let icon: String
    let title: String
    let itemCount: Int
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .foregroundColor(.gray)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/LibraryGroupHeader.swift
git commit -m "Library: add LibraryGroupHeader"
```

---

## Task 12: Rewire `LibraryView` for sort, grouping, and backfill

**Files:**
- Modify: `Diffusely/Views/LibraryView.swift` (full rewrite of the file)

This task replaces the `@Query`-driven body with the sort/group flow. No new unit tests (UI smoke is manual on simulator); the underlying sort service is already covered.

- [ ] **Step 1: Rewrite `LibraryView`**

Replace the entire contents of `Diffusely/Views/LibraryView.swift` with:

```swift
import SwiftUI
import SwiftData

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.modelContext) private var modelContext

    @State private var sortService: LibrarySortService?
    @State private var backfillService: LibraryDateBackfillService?
    @State private var content: LibrarySortService.LibrarySortedContent = .flat([])
    @State private var selectedSort: LibrarySort = .dateNewest
    @State private var expandedGroups: Set<String> = []
    @State private var isInitialLoad = true
    @State private var didRequestDateBackfill = false

    var body: some View {
        content(for: content)
            .navigationTitle("Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySortMenu(selectedSort: $selectedSort)
                }
            }
            .task {
                store.start()
                initializeServices()
                reloadContent()
                await maybeStartBackfill()
            }
            .onChange(of: selectedSort) {
                reloadContent()
                Task { await maybeStartBackfill() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                reloadContent()
            }
    }

    // MARK: - Render

    @ViewBuilder
    private func content(for content: LibrarySortService.LibrarySortedContent) -> some View {
        if content.isEmpty {
            emptyState
        } else {
            ScrollView {
                if store.iCloudStatus == .unavailable {
                    localOnlyBanner
                }
                if let backfill = backfillService, backfill.remaining > 0 {
                    backfillBanner(remaining: backfill.remaining)
                }
                switch content {
                case .flat(let items):
                    flatGrid(items: items)
                    footer(items: items)
                case .grouped(let groups):
                    groupedSections(groups: groups)
                    footer(items: groups.flatMap { $0.items })
                }
            }
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func flatGrid(items: [PersistedLibraryItem]) -> some View {
        MasonryGrid(
            items: items,
            aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
        ) { item in
            NavigationLink {
                LibraryDetailView(itemID: item.itemID)
            } label: {
                thumbnail(for: item)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func groupedSections(groups: [LibrarySortService.LibraryGroup]) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groups) { group in
                Section {
                    if expandedGroups.contains(group.id) {
                        flatGrid(items: group.items)
                            .padding(.bottom, 8)
                    }
                } header: {
                    header(for: group)
                }
            }
        }
    }

    @ViewBuilder
    private func header(for group: LibrarySortService.LibraryGroup) -> some View {
        switch group.kind {
        case .author(let username, let avatarURL):
            AuthorSectionHeader(
                author: CivitaiUser(
                    id: stableAuthorID(for: username),
                    username: username,
                    image: avatarURL
                ),
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .checkpoint(let name):
            LibraryGroupHeader(
                icon: "cube.transparent",
                title: name,
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .bucket(.videos):
            LibraryGroupHeader(
                icon: "film",
                title: "Videos",
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .bucket(.other):
            LibraryGroupHeader(
                icon: "photo.stack",
                title: "Other",
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .bucket(.unknownAuthor):
            LibraryGroupHeader(
                icon: "person.fill.questionmark",
                title: "Unknown",
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        }
    }

    @ViewBuilder
    private func footer(items: [PersistedLibraryItem]) -> some View {
        Text(itemCountText(for: items))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    @ViewBuilder
    private func backfillBanner(remaining: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Backfilling publish dates… \(remaining) remaining")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.gray.opacity(0.08))
    }

    private func itemCountText(for items: [PersistedLibraryItem]) -> String {
        let videos = items.filter { $0.isVideo }.count
        let photos = items.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) Photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) Video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func thumbnail(for item: PersistedLibraryItem) -> some View {
        Color(.secondarySystemBackground)
            .aspectRatio(CGFloat(item.width) / max(1, CGFloat(item.height)), contentMode: .fit)
            .overlay {
                LibraryAsyncImage(
                    itemID: item.itemID,
                    mediaFileName: item.mediaFileName,
                    maxDimension: 600,
                    contentMode: .fill
                )
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.downloadStatus != .downloaded {
                    Image(systemName: "icloud")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Your Library is Empty")
                .font(.headline)
            Text("Use \"Save to Library\" on any image or video to keep your own iCloud-synced copy.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if store.iCloudStatus == .unavailable {
                Text("iCloud is unavailable - items are saved on this device only.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var localOnlyBanner: some View {
        Label("iCloud unavailable - saved on this device only", systemImage: "exclamationmark.icloud")
            .font(.caption)
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.orange.opacity(0.12))
    }

    // MARK: - Actions

    private func initializeServices() {
        if sortService == nil {
            sortService = LibrarySortService(modelContext: modelContext)
        }
    }

    private func reloadContent() {
        guard let sortService else { return }
        let newContent = sortService.sortedLibraryContent(sort: selectedSort)

        // Expansion state: seed all on first load; on subsequent reloads keep
        // existing state and expand any newly-seen groups.
        if case .grouped(let groups) = newContent {
            if isInitialLoad {
                expandedGroups = Set(groups.map { $0.id })
            } else {
                let existing: Set<String>
                if case .grouped(let oldGroups) = content {
                    existing = Set(oldGroups.map { $0.id })
                } else {
                    existing = []
                }
                let newlySeen = Set(groups.map { $0.id }).subtracting(existing)
                expandedGroups.formUnion(newlySeen)
            }
        }

        content = newContent
        isInitialLoad = false
    }

    /// Kick off the publish-date backfill once per `LibraryView` lifetime if
    /// there are items without `publishedAt`. Triggered on first load and on
    /// every sort change (cheap guard: `didRequestDateBackfill`).
    private func maybeStartBackfill() async {
        guard !didRequestDateBackfill,
              let sortService else { return }
        guard sortService.countItemsMissingPublishedDate() > 0 else { return }
        didRequestDateBackfill = true

        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else {
            didRequestDateBackfill = false   // try again later
            return
        }
        let service = LibraryDateBackfillService(
            indexService: store.indexService,
            itemsDirectory: dir,
            fetcher: CivitaiServiceFetchImageAdapter()
        )
        backfillService = service
        await service.runOnce()
        reloadContent()
    }

    private func toggle(_ groupID: String) {
        if expandedGroups.contains(groupID) {
            expandedGroups.remove(groupID)
        } else {
            expandedGroups.insert(groupID)
        }
    }

    /// Stable surrogate id for `AuthorSectionHeader`, which expects an
    /// `Int` user id. Library author rows only carry the username, so we
    /// hash it into a positive Int for the section header to consume.
    /// The collection view's `AuthorSectionHeader` only uses this for
    /// `Identifiable`-style purposes, not for fetching anything.
    private func stableAuthorID(for username: String) -> Int {
        var hasher = Hasher()
        hasher.combine(username)
        return abs(hasher.finalize() & 0x7FFF_FFFF)
    }
}

/// Bridges the live `CivitaiService` to `LibraryDateBackfillService.FetchImageProvider`.
private final class CivitaiServiceFetchImageAdapter: LibraryDateBackfillService.FetchImageProvider {
    private let service = CivitaiService()
    func fetchImage(imageId: Int) async throws -> CivitaiImage {
        try await service.fetchImage(imageId: imageId)
    }
}
```

> Notes on three intentional design choices:
> - We listen to `NSPersistentStoreRemoteChange` instead of using `@Query` so reconcile-driven inserts still show up. If the project doesn't already have this notification firing, replace this with a `.onReceive(store.objectWillChange)` and trust that `LibraryStore.reconcileNow()` mutates published state. The simpler fallback if `NSPersistentStoreRemoteChange` is silent is to `reloadContent()` from `store`'s `objectWillChange` publisher.
> - `stableAuthorID(for:)` produces a non-cryptographic Int surrogate. `AuthorSectionHeader`'s only use of the id is to satisfy `CivitaiUser`'s `Identifiable`; collisions across distinct usernames are vanishingly unlikely and never break correctness because the group is keyed by `LibraryGroup.id` (which uses the actual lowercased username), not by the synthetic int.
> - The backfill service's `fetcher` adapter holds its own `CivitaiService`. That's fine for a one-shot backfill; we don't share state with the rest of the app.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests`
Expected: all tests PASS (no regressions; existing `LibraryTests` still good).

- [ ] **Step 4: Manual smoke (run on simulator)**

Verify on a build with a non-empty library:
1. Open Library tab. Default sort = Date (Newest); items appear in newest-first order.
2. Tap the sort icon in the toolbar. Switch to "Author (A–Z)". Sections appear, headers pinned, all expanded by default.
3. Tap a header. Items collapse. Re-tap. They re-expand.
4. Switch to "Checkpoint (A–Z)". Named checkpoints alphabetical; videos and "Other" buckets at the tail.
5. If you have items saved before this build (no `publishedAt`), confirm a transient "Backfilling publish dates… N remaining" strip appears at the top and disappears when done. Items then reorder into a real date order.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Views/LibraryView.swift
git commit -m "Library: sort + group rendering in LibraryView"
```

---

## Self-Review Notes (for the plan author)

**Spec coverage check:**
- 6 sort cases → Task 1 ✓
- Sidecar v3 with `publishedAt` → Task 2 ✓
- `PersistedLibraryItem` denormalized cols → Task 3 ✓
- `ingest` updates new cols on re-ingest → Task 4 ✓
- Save service writes `publishedAt` → Task 5 ✓
- Sort/group service with flat + grouped + buckets → Task 6 ✓
- Within-group newest-first → Task 6 test ✓
- `countItemsMissingPublishedDate` → Task 6 ✓
- New `image.get` wrapper → Task 7 ✓
- Sidecar-only atomic rewrite helper → Task 8 ✓
- Backfill service (per-item failure tolerance, idempotent re-run) → Task 9 ✓
- `LibrarySortMenu` toolbar → Task 10 ✓
- Checkpoint/bucket pinned header → Task 11 ✓
- `LibraryView` rewire + backfill trigger + expansion state → Task 12 ✓

**Placeholder scan:** no TBDs; every step shows actual code; commit messages explicit.

**Type consistency:**
- `LibrarySort.isAuthorGrouped`/`isCheckpointGrouped`/`isGrouped`/`ascending` defined Task 1, used Tasks 6, 10.
- `LibrarySortService.LibrarySortedContent` cases (`.flat` / `.grouped`) defined Task 6, used Task 12.
- `LibraryGroup.Kind` cases (`.author`, `.checkpoint`, `.bucket(.videos|.other|.unknownAuthor)`) defined Task 6, used Task 12 header switch.
- `LibraryDateBackfillService.FetchImageProvider` defined Task 9, conformed by `CivitaiServiceFetchImageAdapter` in Task 12.
- `LibraryFileWriter.rewriteMetadata` defined Task 8, used in Task 9.
- `LibraryIndexService.currentDownloadStatus(itemID:)` added in Task 9, used in Task 9.
- `LibrarySortService.countItemsMissingPublishedDate()` defined Task 6, used Task 12.

All cross-task references resolve.
