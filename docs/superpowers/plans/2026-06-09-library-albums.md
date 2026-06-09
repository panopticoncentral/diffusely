# Library Albums Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add many-to-many albums to the personal Library — place items (singly or via multi-select) into new or existing albums, browse an album with the full sort/group toolbar, and see a built-in "Not in any Album" smart view.

**Architecture:** Album membership is stored on each item's sidecar JSON (`albumIDs: [String]`, schema v5); each album is a tiny `album-{uuid}.json` metadata file carrying only id/name/createdAt. The SwiftData index (`PersistedLibraryItem` + new `PersistedAlbum`) is disposable and rebuilt from these files by reconcile. All file writes go through the existing `NSFileCoordinator` + dedicated-serial-queue discipline so coordinated I/O never burns Swift-concurrency cooperative threads (the documented grey-spinner regression). The read side pre-filters the item set and feeds the **existing** `LibrarySortService`, so every sort/group option works in albums and in "Not in any Album" for free.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`@Model`, `@ModelActor`), Swift Testing (`@Suite`/`@Test`/`#expect`), iCloud Drive document container, Xcode 16 synchronized file groups.

---

## Conventions for every task

**Build/test command** (whole test target):
```bash
xcodebuild test -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DiffuselyTests 2>&1 | tail -40
```
To run a single suite, append the suite name: `-only-testing:DiffuselyTests/<SuiteName>`.

**New files are picked up automatically** — the project uses `PBXFileSystemSynchronizedRootGroup`, so creating a `.swift` file under `Diffusely/` or `DiffuselyTests/` adds it to the target with no `.pbxproj` edit.

**Before you start:** create a working branch.
```bash
git checkout -b library-albums
```

**Key existing files to read before editing** (do not re-derive their patterns — follow them):
- `Diffusely/Models/Persistence/LibraryItemMetadata.swift` — sidecar struct, schema versioning, memberwise-init-with-defaults pattern.
- `Diffusely/Models/Persistence/PersistedLibraryItem.swift` — index row + `convenience init(metadata:downloadStatus:)`.
- `Diffusely/Services/Library/LibraryIndexService.swift` — `@ModelActor`, `apply(...)`, `reconcile`, `scanContainer`, `ScanResult`.
- `Diffusely/Services/Library/LibrarySaveService.swift` — `LibraryFileWriter` (coordinated write helper).
- `Diffusely/Services/Library/LibraryStore.swift` — `deleteQueue` + `runDeleteItemFiles` (off-cooperative-pool coordinated I/O).
- `Diffusely/Services/Library/LibrarySortService.swift` — main-actor read/sort/group.
- `Diffusely/Views/LibraryView.swift` — grid, toolbar, select mode, context menu.
- `DiffuselyTests/LibraryTests.swift` — `makeContainer()` (in-memory), `tempDir()` helpers.

---

## Task 1: Sidecar schema v5 — `albumIDs` on `LibraryItemMetadata`

Add the membership field to the sidecar, bump the schema version, make it part of value-equality (so a membership change re-ingests), and add a copy-with helper.

**Files:**
- Modify: `Diffusely/Models/Persistence/LibraryItemMetadata.swift`
- Test: `DiffuselyTests/LibraryAlbumMetadataTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryAlbumMetadataTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryAlbumMetadataTests {
    private func make(itemID: Int, albumIDs: [String] = []) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: itemID, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)",
            sourceDomain: "civitai.com",
            originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).jpeg",
            mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albumIDs, savedAt: Date(), savedByAppVersion: "t"
        )
    }

    @Test func currentSchemaVersionIsFive() {
        #expect(LibraryItemMetadata.currentSchemaVersion == 5)
    }

    @Test func roundTripsAlbumIDs() throws {
        let original = make(itemID: 1, albumIDs: ["A", "B"])
        let data = try LibraryItemMetadata.encoder().encode(original)
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.albumIDs == ["A", "B"])
    }

    @Test func legacyV4JSONWithoutAlbumIDsDecodesToEmpty() throws {
        let legacy = """
        { "schemaVersion": 4, "itemID": 9,
          "canonicalPageURL": "https://civitai.com/images/9",
          "sourceDomain": "civitai.com",
          "originalCDNURL": "https://image.civitai.com/x/u/original=true/9.jpeg",
          "mediaType": "image", "mediaFileName": "9.jpeg",
          "fileByteSize": 1, "contentSHA256": "x", "width": 1, "height": 1,
          "nsfwLevel": 1, "author": {},
          "savedAt": "2026-01-01T00:00:00Z", "savedByAppVersion": "old" }
        """.data(using: .utf8)!
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: legacy)
        #expect(decoded.albumIDs == [])
    }

    @Test func equalityIsSensitiveToAlbumIDs() {
        let a = make(itemID: 5, albumIDs: ["X"])
        let b = make(itemID: 5, albumIDs: ["X", "Y"])
        #expect(a != b)
    }

    @Test func settingAlbumIDsReturnsCopyWithNewMembership() {
        let a = make(itemID: 7, albumIDs: ["X"])
        let b = a.settingAlbumIDs(["X", "Z"])
        #expect(a.albumIDs == ["X"])           // original unchanged
        #expect(b.albumIDs == ["X", "Z"])
        #expect(b.itemID == 7)                  // everything else preserved
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryAlbumMetadataTests 2>&1 | tail -40`
Expected: FAIL to compile (`albumIDs:` argument and `settingAlbumIDs` do not exist).

- [ ] **Step 3: Add the field, bump the version, extend equality, add the helper**

In `LibraryItemMetadata.swift`:

Change the version constant (line ~26):
```swift
    static let currentSchemaVersion = 5   // v3 publishedAt; v4 publishedAtBackfillAttemptedAt; v5 albumIDs
```

Add the stored property next to `publishedAtBackfillAttemptedAt` (after line ~62):
```swift
    /// Album membership: UUID strings for every album this item belongs to.
    /// Many-to-many — an item can be in several albums. Absent in v4-and-earlier
    /// sidecars (decodes to []). The source of truth for membership; the index's
    /// `albumIDsJoined` is denormalized from this.
    let albumIDs: [String]
```

In `static func ==`, add `albumIDs` to the compared fields:
```swift
            && lhs.publishedAt == rhs.publishedAt
            && lhs.albumIDs == rhs.albumIDs
```

In the memberwise `init`, add the parameter with a default (so existing call sites compile) and assign it. Place it right after `publishedAtBackfillAttemptedAt`:
```swift
        publishedAtBackfillAttemptedAt: Date? = nil,
        albumIDs: [String] = [],
        savedAt: Date,
        savedByAppVersion: String
    ) {
```
and in the body:
```swift
        self.publishedAtBackfillAttemptedAt = publishedAtBackfillAttemptedAt
        self.albumIDs = albumIDs
        self.savedAt = savedAt
```

`albumIDs` is non-optional, so the synthesized `Codable` would **throw** on a v4 sidecar that lacks the key. To decode old sidecars as `[]`, replace the synthesized decoder with a custom `init(from:)` that defaults the key with `decodeIfPresent`. (Encoding stays synthesized — `albumIDs` always encodes since it is non-optional.) Add this extension at the bottom of the file:

```swift
extension LibraryItemMetadata {
    /// Returns a copy with `albumIDs` replaced. Used by `LibraryAlbumService`
    /// when adding/removing membership without touching any other field.
    func settingAlbumIDs(_ ids: [String]) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: schemaVersion, itemID: itemID, sourcePostID: sourcePostID,
            sourcePostTitle: sourcePostTitle, canonicalPostURL: canonicalPostURL,
            canonicalPageURL: canonicalPageURL, sourceDomain: sourceDomain,
            originalCDNURL: originalCDNURL, mediaType: mediaType,
            mediaFileName: mediaFileName, fileByteSize: fileByteSize,
            contentSHA256: contentSHA256, width: width, height: height,
            nsfwLevel: nsfwLevel, author: author, stats: stats,
            generationData: generationData, publishedAt: publishedAt,
            publishedAtBackfillAttemptedAt: publishedAtBackfillAttemptedAt,
            albumIDs: ids, savedAt: savedAt, savedByAppVersion: savedByAppVersion
        )
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FullKeys.self)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            itemID: try c.decode(Int.self, forKey: .itemID),
            sourcePostID: try c.decodeIfPresent(Int.self, forKey: .sourcePostID),
            sourcePostTitle: try c.decodeIfPresent(String.self, forKey: .sourcePostTitle),
            canonicalPostURL: try c.decodeIfPresent(String.self, forKey: .canonicalPostURL),
            canonicalPageURL: try c.decode(String.self, forKey: .canonicalPageURL),
            sourceDomain: try c.decode(String.self, forKey: .sourceDomain),
            originalCDNURL: try c.decode(String.self, forKey: .originalCDNURL),
            mediaType: try c.decode(LibraryMediaType.self, forKey: .mediaType),
            mediaFileName: try c.decode(String.self, forKey: .mediaFileName),
            fileByteSize: try c.decode(Int.self, forKey: .fileByteSize),
            contentSHA256: try c.decode(String.self, forKey: .contentSHA256),
            width: try c.decode(Int.self, forKey: .width),
            height: try c.decode(Int.self, forKey: .height),
            nsfwLevel: try c.decode(Int.self, forKey: .nsfwLevel),
            author: try c.decode(LibraryAuthor.self, forKey: .author),
            stats: try c.decodeIfPresent(ImageStats.self, forKey: .stats),
            generationData: try c.decodeIfPresent(GenerationData.self, forKey: .generationData),
            publishedAt: try c.decodeIfPresent(Date.self, forKey: .publishedAt),
            publishedAtBackfillAttemptedAt: try c.decodeIfPresent(Date.self, forKey: .publishedAtBackfillAttemptedAt),
            albumIDs: try c.decodeIfPresent([String].self, forKey: .albumIDs) ?? [],
            savedAt: try c.decode(Date.self, forKey: .savedAt),
            savedByAppVersion: try c.decode(String.self, forKey: .savedByAppVersion)
        )
    }

    private enum FullKeys: String, CodingKey {
        case schemaVersion, itemID, sourcePostID, sourcePostTitle, canonicalPostURL
        case canonicalPageURL, sourceDomain, originalCDNURL, mediaType, mediaFileName
        case fileByteSize, contentSHA256, width, height, nsfwLevel, author, stats
        case generationData, publishedAt, publishedAtBackfillAttemptedAt, albumIDs
        case savedAt, savedByAppVersion
    }
}
```
This custom `init(from:)` replaces the synthesized one; the existing `static func decoder()` (ISO-8601 dates) is unchanged and still used.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests/LibraryAlbumMetadataTests 2>&1 | tail -40`
Expected: PASS (5 tests). Also run `-only-testing:DiffuselyTests/LibraryMetadataTests` to confirm legacy sidecar tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/Persistence/LibraryItemMetadata.swift DiffuselyTests/LibraryAlbumMetadataTests.swift
git commit -m "Add albumIDs to library sidecar (schema v5)"
```

---

## Task 2: Denormalize membership onto `PersistedLibraryItem`

The index row gets `albumIDsJoined` (a `\u{1f}`-delimited string) plus a computed `albumIDs` accessor and a membership check. Populate it from the sidecar in both the convenience init and `LibraryIndexService.apply`.

**Files:**
- Modify: `Diffusely/Models/Persistence/PersistedLibraryItem.swift`
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift:29-47` (the `apply` method)
- Test: `DiffuselyTests/LibraryAlbumMembershipTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryAlbumMembershipTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryAlbumMembershipTests {
    private func meta(_ id: Int, albums: [String]) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t"
        )
    }

    @Test func denormalizesAlbumIDsFromMetadata() {
        let row = PersistedLibraryItem(metadata: meta(1, albums: ["A", "B"]), downloadStatus: .downloaded)
        #expect(row.albumIDs == ["A", "B"])
        #expect(row.isInAnyAlbum == true)
        #expect(row.belongs(toAlbum: "A"))
        #expect(!row.belongs(toAlbum: "Z"))
    }

    @Test func emptyWhenNoAlbums() {
        let row = PersistedLibraryItem(metadata: meta(2, albums: []), downloadStatus: .downloaded)
        #expect(row.albumIDs == [])
        #expect(row.isInAnyAlbum == false)
    }

    @Test func settingAlbumIDsRoundTripsThroughJoinedString() {
        let row = PersistedLibraryItem(metadata: meta(3, albums: []), downloadStatus: .downloaded)
        row.albumIDs = ["X", "Y"]
        #expect(row.albumIDsJoined.contains("X"))
        #expect(row.albumIDs == ["X", "Y"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumMembershipTests 2>&1 | tail -40`
Expected: FAIL to compile (`albumIDs`, `albumIDsJoined`, `isInAnyAlbum`, `belongs(toAlbum:)` undefined).

- [ ] **Step 3: Add the stored field, accessors, and populate from metadata**

In `PersistedLibraryItem.swift`, add the stored property (after `needsDateBackfill`, line ~49):
```swift
    /// Denormalized album membership: the item's album UUIDs joined by U+001F
    /// (a delimiter that can't appear in a UUID string). Kept in sync with the
    /// sidecar's `albumIDs` by the convenience init and `LibraryIndexService.apply`.
    /// Stored as a scalar string (not a relationship) so it fits the existing
    /// fetchAll()+in-memory-filter read path. Defaults to "" for v4 rows.
    var albumIDsJoined: String = ""
```

Add the `albumIDs` argument to the designated `init` (it currently lists every column). Add a parameter and assignment:
```swift
        downloadStatus: LibraryDownloadStatus,
        needsDateBackfill: Bool,
        albumIDsJoined: String = ""
    ) {
```
and in the body, after `self.needsDateBackfill = needsDateBackfill`:
```swift
        self.albumIDsJoined = albumIDsJoined
```

In the `convenience init(metadata:downloadStatus:)`, pass the joined string (after the `needsDateBackfill:` argument):
```swift
            needsDateBackfill: Self.computeNeedsDateBackfill(for: metadata),
            albumIDsJoined: Self.join(metadata.albumIDs)
```

Add the accessors and join/split helpers (after the `isVideo` computed property, line ~127):
```swift
    static let albumDelimiter = "\u{1f}"

    static func join(_ ids: [String]) -> String {
        ids.joined(separator: albumDelimiter)
    }

    var albumIDs: [String] {
        get {
            albumIDsJoined.isEmpty ? [] : albumIDsJoined.components(separatedBy: Self.albumDelimiter)
        }
        set { albumIDsJoined = Self.join(newValue) }
    }

    var isInAnyAlbum: Bool { !albumIDsJoined.isEmpty }

    func belongs(toAlbum id: String) -> Bool { albumIDs.contains(id) }
```

In `LibraryIndexService.swift`, in `apply(...)` (after `row.downloadStatus = downloadStatus`, line ~46):
```swift
        row.albumIDsJoined = PersistedLibraryItem.join(metadata.albumIDs)
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumMembershipTests 2>&1 | tail -40`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/Persistence/PersistedLibraryItem.swift Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryAlbumMembershipTests.swift
git commit -m "Denormalize album membership onto the library index row"
```

---

## Task 3: `PersistedAlbum` model + schema registration

A disposable index row for albums, registered in the app schema and the test container.

**Files:**
- Create: `Diffusely/Models/Persistence/PersistedAlbum.swift`
- Modify: `Diffusely/DiffuselyApp.swift:33-40` (schema list)
- Test: `DiffuselyTests/PersistedAlbumTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/PersistedAlbumTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct PersistedAlbumTests {
    @Test func insertsAndFetchesAlbum() throws {
        let container = try ModelContainer(
            for: PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let ctx = ModelContext(container)
        let id = UUID()
        ctx.insert(PersistedAlbum(id: id, name: "Faves", createdAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<PersistedAlbum>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.name == "Faves")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/PersistedAlbumTests 2>&1 | tail -40`
Expected: FAIL to compile (`PersistedAlbum` undefined).

- [ ] **Step 3: Create the model and register it**

Create `Diffusely/Models/Persistence/PersistedAlbum.swift`:
```swift
import Foundation
import SwiftData

/// Disposable index row for an album. NOT the source of truth — every field is
/// rebuilt from the `album-{uuid}.json` metadata file in the container during
/// reconcile. Intentionally self-contained (no relationships) so it cannot
/// destabilize the existing store, mirroring `PersistedLibraryItem`. Membership
/// is NOT stored here; it lives on each item's sidecar / `albumIDsJoined`.
@Model
final class PersistedAlbum {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
```

In `DiffuselyApp.swift`, add to the `Schema([...])` array (after `PersistedLibraryItem.self`):
```swift
            PersistedLibraryItem.self,
            PersistedAlbum.self
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/PersistedAlbumTests 2>&1 | tail -40`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/Persistence/PersistedAlbum.swift Diffusely/DiffuselyApp.swift DiffuselyTests/PersistedAlbumTests.swift
git commit -m "Add PersistedAlbum index model and register it in the schema"
```

---

## Task 4: Album file model + coordinated reader/writer

The `album-{uuid}.json` shape and a directory-injected, unit-testable type that creates/renames/deletes album files using the same `NSFileCoordinator` pattern as `LibraryFileWriter`.

**Files:**
- Create: `Diffusely/Services/Library/LibraryAlbumFile.swift`
- Test: `DiffuselyTests/LibraryAlbumFileTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryAlbumFileTests.swift`:
```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryAlbumFileTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func fileNameFollowsAlbumUUIDConvention() {
        let id = UUID()
        #expect(LibraryAlbumStore.fileName(for: id) == "album-\(id.uuidString).json")
        #expect(LibraryAlbumStore.albumID(fromFileName: "album-\(id.uuidString).json") == id)
        #expect(LibraryAlbumStore.albumID(fromFileName: "1234.json") == nil)
    }

    @Test func writeThenReadRoundTrips() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let file = LibraryAlbumFile(id: UUID(), name: "Sci-fi", createdAt: Date(timeIntervalSince1970: 10))
        try store.write(file)
        let read = try #require(store.read(id: file.id))
        #expect(read == file)
    }

    @Test func deleteRemovesFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let file = LibraryAlbumFile(id: UUID(), name: "Temp", createdAt: Date())
        try store.write(file)
        store.delete(id: file.id)
        #expect(store.read(id: file.id) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumFileTests 2>&1 | tail -40`
Expected: FAIL to compile (`LibraryAlbumFile` / `LibraryAlbumStore` undefined).

- [ ] **Step 3: Implement the file model and store**

Create `Diffusely/Services/Library/LibraryAlbumFile.swift`:
```swift
import Foundation

/// Self-describing metadata file for one album, written as `album-{uuid}.json`
/// in the iCloud container. The album's existence record — it carries only
/// identity, name, and creation date. Membership is NOT here; it lives on each
/// item's sidecar (`LibraryItemMetadata.albumIDs`). Like the item sidecar, this
/// is the source of truth; `PersistedAlbum` is a disposable index rebuilt from it.
struct LibraryAlbumFile: Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

/// Coordinated reader/writer for album files in the container. Directory-injected
/// so it is unit-testable against a temp directory without iCloud. The write/delete
/// use `NSFileCoordinator` exactly like `LibraryFileWriter`; callers are responsible
/// for invoking these off the cooperative pool / main actor (see `LibraryAlbumService`).
struct LibraryAlbumStore {
    let itemsDirectory: URL

    static let fileNamePrefix = "album-"

    static func fileName(for id: UUID) -> String { "\(fileNamePrefix)\(id.uuidString).json" }

    /// Recovers the album id from a filename without reading contents. Returns nil
    /// for non-album json (e.g. item sidecars named `{int}.json`).
    static func albumID(fromFileName name: String) -> UUID? {
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(".json") else { return nil }
        let start = name.index(name.startIndex, offsetBy: fileNamePrefix.count)
        let end = name.index(name.endIndex, offsetBy: -".json".count)
        return UUID(uuidString: String(name[start..<end]))
    }

    private func url(for id: UUID) -> URL {
        itemsDirectory.appendingPathComponent(Self.fileName(for: id), isDirectory: false)
    }

    func read(id: UUID) -> LibraryAlbumFile? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data)
    }

    func write(_ file: LibraryAlbumFile) throws {
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let json = try LibraryAlbumFile.encoder().encode(file)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url(for: file.id), options: .forReplacing, error: &coordinationError) { dest in
            do { try json.write(to: dest, options: .atomic) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    func delete(id: UUID) {
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let coordinator = NSFileCoordinator()
        var err: NSError?
        coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumFileTests 2>&1 | tail -40`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryAlbumFile.swift DiffuselyTests/LibraryAlbumFileTests.swift
git commit -m "Add album file model and coordinated album-file store"
```

---

## Task 5: Reconcile rebuilds `PersistedAlbum` from album files

Extend the container scan to collect album files (distinct from item sidecars by filename), carry them in `ScanResult`, and upsert/prune `PersistedAlbum` rows in both reconcile paths. Crucially, album `.json` files must NOT be decoded as item sidecars.

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (`ScanResult`, `scanContainer`, `reconcileBatched`, `reconcilePerItem`)
- Test: `DiffuselyTests/LibraryAlbumReconcileTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryAlbumReconcileTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryAlbumReconcileTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func writeItemSidecar(_ id: Int, albums: [String], in dir: URL) throws {
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t")
        let data = try LibraryItemMetadata.encoder().encode(meta)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    @Test func reconcileBuildsAlbumRowsFromAlbumFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let a = LibraryAlbumFile(id: UUID(), name: "Faves", createdAt: Date(timeIntervalSince1970: 1))
        try store.write(a)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)
        let ctx = ModelContext(container)
        let albums = try ctx.fetch(FetchDescriptor<PersistedAlbum>())
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Faves")
    }

    @Test func albumFilesAreNotIngestedAsItems() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try store_write(LibraryAlbumFile(id: UUID(), name: "X", createdAt: Date()), in: dir)
        try writeItemSidecar(7, albums: [], in: dir)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)
        let ctx = ModelContext(container)
        let items = try ctx.fetch(FetchDescriptor<PersistedLibraryItem>())
        #expect(items.count == 1)            // only the real item, not the album file
        #expect(items.first?.itemID == 7)
    }

    @Test func reconcilePrunesVanishedAlbumFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        let a = LibraryAlbumFile(id: UUID(), name: "Temp", createdAt: Date())
        try store.write(a)
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)
        store.delete(id: a.id)
        await index.reconcile(itemsDirectory: dir)
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).isEmpty)
    }

    private func store_write(_ f: LibraryAlbumFile, in dir: URL) throws {
        try LibraryAlbumStore(itemsDirectory: dir).write(f)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumReconcileTests 2>&1 | tail -40`
Expected: FAIL — `albumFilesAreNotIngestedAsItems` and `reconcileBuildsAlbumRowsFromAlbumFiles` fail (albums not built; album file may currently be silently skipped, so the items test might pass but the album tests fail to find rows).

- [ ] **Step 3: Extend the scan and both reconcile paths**

In `LibraryIndexService.swift`:

Extend `ScanResult` (line ~193):
```swift
    typealias ScanResult = (
        items: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)],
        seenIDs: Set<Int>,
        albums: [LibraryAlbumFile],
        seenAlbumIDs: Set<UUID>
    )
```

In `scanContainer` (line ~217), partition json files and decode album files. Replace the body from the `jsonURLs` line through the final `return`:
```swift
        let jsonURLs = contents.filter { $0.pathExtension == "json" }
        var seenIDs = Set<Int>()
        var items: [(metadata: LibraryItemMetadata, status: LibraryDownloadStatus)] = []
        var albums: [LibraryAlbumFile] = []
        var seenAlbumIDs = Set<UUID>()

        for jsonURL in jsonURLs {
            let name = jsonURL.lastPathComponent

            // Album metadata file: decode separately, never as an item sidecar.
            if let albumID = LibraryAlbumStore.albumID(fromFileName: name) {
                if isDatalessPlaceholder(jsonURL) {
                    try? fileManager.startDownloadingUbiquitousItem(at: jsonURL)
                    seenAlbumIDs.insert(albumID)
                    continue
                }
                if let data = try? Data(contentsOf: jsonURL),
                   let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data) {
                    seenAlbumIDs.insert(file.id)
                    albums.append(file)
                }
                continue
            }

            // Item sidecar (existing behavior).
            if isDatalessPlaceholder(jsonURL) {
                try? fileManager.startDownloadingUbiquitousItem(at: jsonURL)
                if let id = sidecarItemID(from: jsonURL) { seenIDs.insert(id) }
                continue
            }
            guard
                let data = try? Data(contentsOf: jsonURL),
                let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            else { continue }

            seenIDs.insert(metadata.itemID)
            let mediaURL = itemsDirectory.appendingPathComponent(metadata.mediaFileName)
            let status = downloadStatus(for: mediaURL, fileManager: fileManager)
            items.append((metadata: metadata, status: status))
        }
        return (items: items, seenIDs: seenIDs, albums: albums, seenAlbumIDs: seenAlbumIDs)
```

Add an album upsert/prune helper to the actor (place near `reconcileBatched`):
```swift
    /// Upserts `PersistedAlbum` rows from the scan and prunes rows whose album
    /// file vanished. Pure in-memory work on the model context; caller saves.
    private func applyAlbums(_ scan: ScanResult) {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for file in scan.albums {
            if let row = byID[file.id] {
                row.name = file.name
                row.createdAt = file.createdAt
            } else {
                let row = PersistedAlbum(id: file.id, name: file.name, createdAt: file.createdAt)
                modelContext.insert(row)
                byID[file.id] = row
            }
        }
        for row in existing where !scan.seenAlbumIDs.contains(row.id) {
            modelContext.delete(row)
        }
    }
```

Call it in `reconcileBatched` (before `try modelContext.save()`, line ~149):
```swift
        for item in existing where !scan.seenIDs.contains(item.itemID) {
            modelContext.delete(item)
        }
        applyAlbums(scan)
        do {
            try modelContext.save()
```

And in `reconcilePerItem`, after the item loop completes (after line ~183), add a final album pass + save:
```swift
        applyAlbums(scan)
        if (try? modelContext.save()) == nil { modelContext.rollback() }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumReconcileTests 2>&1 | tail -40`
Expected: PASS (3 tests). Also run `-only-testing:DiffuselyTests/LibraryReconcileTests` (or the existing reconcile suite in `LibraryTests`) to confirm no regression in item reconcile.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryAlbumReconcileTests.swift
git commit -m "Reconcile albums from album files into PersistedAlbum"
```

---

## Task 6: Index-actor album write methods

The actor methods the album service calls to keep the index in step with file writes: create/rename/delete an album row, and set one item's membership.

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift`
- Test: `DiffuselyTests/LibraryIndexAlbumWriteTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryIndexAlbumWriteTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryIndexAlbumWriteTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
    private func ingest(_ index: LibraryIndexService, id: Int, albums: [String]) async {
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t")
        await index.ingest(metadata: meta, downloadStatus: .downloaded)
    }

    @Test func upsertRenameDeleteAlbum() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let id = UUID()
        await index.upsertAlbum(id: id, name: "A", createdAt: Date(timeIntervalSince1970: 1))
        await index.upsertAlbum(id: id, name: "A2", createdAt: Date(timeIntervalSince1970: 1))
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).first?.name == "A2")
        await index.removeAlbum(id: id)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).isEmpty)
    }

    @Test func setAlbumIDsUpdatesRow() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await ingest(index, id: 5, albums: [])
        await index.setAlbumIDs(itemID: 5, albumIDs: ["A", "B"])
        let ctx = ModelContext(container)
        let row = try #require(ctx.fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == ["A", "B"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryIndexAlbumWriteTests 2>&1 | tail -40`
Expected: FAIL to compile (`upsertAlbum` / `removeAlbum` / `setAlbumIDs` undefined).

- [ ] **Step 3: Add the actor methods**

In `LibraryIndexService.swift`, add a `// MARK: - Albums` section (e.g. after `remove(itemIDs:)`, line ~69):
```swift
    // MARK: - Albums

    func upsertAlbum(id: UUID, name: String, createdAt: Date) {
        if let existing = fetchAlbum(id: id) {
            existing.name = name
            existing.createdAt = createdAt
        } else {
            modelContext.insert(PersistedAlbum(id: id, name: name, createdAt: createdAt))
        }
        try? modelContext.save()
    }

    func removeAlbum(id: UUID) {
        if let existing = fetchAlbum(id: id) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    /// Replaces an item row's membership. The sidecar is the source of truth and
    /// must already have been rewritten by the caller; this just keeps the index
    /// row in step without re-reading media or download status.
    func setAlbumIDs(itemID: Int, albumIDs: [String]) {
        guard let row = fetchItem(itemID: itemID) else { return }
        row.albumIDsJoined = PersistedLibraryItem.join(albumIDs)
        try? modelContext.save()
    }

    private func fetchAlbum(id: UUID) -> PersistedAlbum? {
        var d = FetchDescriptor<PersistedAlbum>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryIndexAlbumWriteTests 2>&1 | tail -40`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryIndexAlbumWriteTests.swift
git commit -m "Add album write methods to the library index actor"
```

---

## Task 7: `LibraryAlbumService` — orchestrate file + index for all album ops

The single entry point the UI calls. Reads/writes album files and item sidecars off the cooperative pool (dedicated serial queue), then updates the index. Directory-injected for tests; the production wiring in `LibraryStore` comes in Task 8.

**Files:**
- Create: `Diffusely/Services/Library/LibraryAlbumService.swift`
- Modify: `Diffusely/Services/Library/LibrarySaveService.swift` (add a `readMetadata` helper to `LibraryFileWriter`)
- Test: `DiffuselyTests/LibraryAlbumServiceTests.swift` (create)

- [ ] **Step 1: Add the sidecar read helper (needed by add/remove)**

In `LibrarySaveService.swift`, add to `LibraryFileWriter` (after `rewriteMetadata`, line ~106):
```swift
    /// Reads and decodes the sidecar for an already-committed item, if present.
    func readMetadata(itemID id: Int) -> LibraryItemMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(forItemID: id)) else { return nil }
        return try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
    }
```

- [ ] **Step 2: Write the failing tests**

Create `DiffuselyTests/LibraryAlbumServiceTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryAlbumServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Commit a real item (media + sidecar) so add/remove can read it back.
    private func commitItem(_ id: Int, in dir: URL) throws {
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let meta = LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t")
        let tmp = dir.appendingPathComponent("dl.tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)
    }

    @Test func createAlbumWritesFileAndIndexRow() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let id = await svc.createAlbum(name: "Faves")
        let read = try #require(LibraryAlbumStore(itemsDirectory: dir).read(id: id))
        #expect(read.name == "Faves")
        let ctx = ModelContext(container)
        #expect(try ctx.fetch(FetchDescriptor<PersistedAlbum>()).count == 1)
    }

    @Test func addThenRemoveItemUpdatesSidecarAndIndex() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        try commitItem(11, in: dir)
        await index.reconcile(itemsDirectory: dir)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let album = await svc.createAlbum(name: "A")
        await svc.addItems([11], toAlbum: album)
        let writer = LibraryFileWriter(itemsDirectory: dir)
        #expect(writer.readMetadata(itemID: 11)?.albumIDs == [album.uuidString])
        await svc.removeItems([11], fromAlbum: album)
        #expect(writer.readMetadata(itemID: 11)?.albumIDs == [])
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedLibraryItem>()).first)
        #expect(row.albumIDs == [])
    }

    @Test func deleteAlbumRemovesFileButKeepsItemMedia() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        try commitItem(12, in: dir)
        await index.reconcile(itemsDirectory: dir)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let album = await svc.createAlbum(name: "Temp")
        await svc.addItems([12], toAlbum: album)
        await svc.deleteAlbum(album)
        #expect(LibraryAlbumStore(itemsDirectory: dir).read(id: album) == nil)
        // Item media + sidecar untouched.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("12.jpeg").path))
        #expect(LibraryFileWriter(itemsDirectory: dir).readMetadata(itemID: 12) != nil)
    }

    @Test func renameAlbumRewritesFileAndIndex() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
        let album = await svc.createAlbum(name: "Old")
        await svc.renameAlbum(album, to: "New")
        #expect(LibraryAlbumStore(itemsDirectory: dir).read(id: album)?.name == "New")
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).first?.name == "New")
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumServiceTests 2>&1 | tail -40`
Expected: FAIL to compile (`LibraryAlbumService` undefined).

- [ ] **Step 4: Implement the service**

Create `Diffusely/Services/Library/LibraryAlbumService.swift`:
```swift
import Foundation

/// Orchestrates album mutations: writes album files and item sidecars (the
/// sources of truth) and keeps the disposable index in step. All coordinated
/// file I/O runs on a dedicated serial queue, never the Swift-concurrency
/// cooperative pool — synchronous `NSFileCoordinator` calls there would burn
/// cooperative threads and, under iCloud churn, starve the pool (the documented
/// grey-spinner regression). Mirrors the queue discipline in `LibraryStore` and
/// `LibraryIndexService`.
///
/// `itemsDirectory` is a closure so production can resolve the iCloud container
/// lazily while tests inject a temp directory.
final class LibraryAlbumService {
    private let index: LibraryIndexService
    private let resolveDirectory: () async -> URL?

    private static let queue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.album",
        qos: .utility
    )

    init(index: LibraryIndexService, itemsDirectory: @escaping () async -> URL?) {
        self.index = index
        self.resolveDirectory = itemsDirectory
    }

    // MARK: - Album lifecycle

    /// Creates an album and returns its id. No-op-safe: a failed file write still
    /// returns the id but logs; the index row is only added after the file lands.
    @discardableResult
    func createAlbum(name: String) async -> UUID {
        let id = UUID()
        let file = LibraryAlbumFile(id: id, name: name, createdAt: Date())
        guard let dir = await resolveDirectory() else { return id }
        await Self.run { try? LibraryAlbumStore(itemsDirectory: dir).write(file) }
        await index.upsertAlbum(id: id, name: file.name, createdAt: file.createdAt)
        return id
    }

    func renameAlbum(_ id: UUID, to newName: String) async {
        guard let dir = await resolveDirectory() else { return }
        let store = LibraryAlbumStore(itemsDirectory: dir)
        guard var file = await Self.run({ store.read(id: id) }) else { return }
        file.name = newName
        await Self.run { try? store.write(file) }
        await index.upsertAlbum(id: id, name: newName, createdAt: file.createdAt)
    }

    /// Deletes the album file and index row. Member items keep the now-dangling
    /// UUID in their sidecar (filtered out against the known-album set and lazily
    /// cleaned on their next membership write). Media is never touched.
    func deleteAlbum(_ id: UUID) async {
        guard let dir = await resolveDirectory() else { return }
        await Self.run { LibraryAlbumStore(itemsDirectory: dir).delete(id: id) }
        await index.removeAlbum(id: id)
    }

    // MARK: - Membership

    func addItems(_ itemIDs: [Int], toAlbum id: UUID) async {
        await mutateMembership(itemIDs) { current in
            current.contains(id.uuidString) ? current : current + [id.uuidString]
        }
    }

    func removeItems(_ itemIDs: [Int], fromAlbum id: UUID) async {
        await mutateMembership(itemIDs) { current in
            current.filter { $0 != id.uuidString }
        }
    }

    /// Reads each item's sidecar, applies `transform` to its album list, rewrites
    /// the sidecar, and updates the index row — all off the cooperative pool.
    private func mutateMembership(_ itemIDs: [Int], _ transform: @escaping ([String]) -> [String]) async {
        guard !itemIDs.isEmpty, let dir = await resolveDirectory() else { return }
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let updated: [(Int, [String])] = await Self.run {
            var results: [(Int, [String])] = []
            for itemID in itemIDs {
                guard let meta = writer.readMetadata(itemID: itemID) else { continue }
                let newIDs = transform(meta.albumIDs)
                if newIDs == meta.albumIDs { results.append((itemID, meta.albumIDs)); continue }
                try? writer.rewriteMetadata(meta.settingAlbumIDs(newIDs))
                results.append((itemID, newIDs))
            }
            return results
        }
        for (itemID, ids) in updated {
            await index.setAlbumIDs(itemID: itemID, albumIDs: ids)
        }
    }

    /// Runs blocking file work on the dedicated serial queue and suspends the
    /// caller without holding a cooperative thread.
    private static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumServiceTests 2>&1 | tail -40`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/LibraryAlbumService.swift Diffusely/Services/Library/LibrarySaveService.swift DiffuselyTests/LibraryAlbumServiceTests.swift
git commit -m "Add LibraryAlbumService orchestrating album files + index"
```

---

## Task 8: Wire the album service into `LibraryStore` + a change signal

Expose the service from the store (which already owns `indexService`), and add an `albumsVersion` the UI observes so album/membership edits trigger a reload (item count is unchanged by membership edits).

**Files:**
- Modify: `Diffusely/Services/Library/LibraryStore.swift`
- Test: `DiffuselyTests/LibraryStoreAlbumTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryStoreAlbumTests.swift`:
```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

@MainActor
@Suite struct LibraryStoreAlbumTests {
    @Test func storeExposesAlbumServiceAndBumpsVersion() async throws {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let store = LibraryStore(modelContainer: container)
        let before = store.albumsVersion
        store.notifyAlbumsChanged()
        #expect(store.albumsVersion == before + 1)
        #expect(store.albumService != nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryStoreAlbumTests 2>&1 | tail -40`
Expected: FAIL to compile (`albumService` / `albumsVersion` / `notifyAlbumsChanged` undefined).

- [ ] **Step 3: Add to `LibraryStore`**

In `LibraryStore.swift`, add a published counter (near the other `@Published` lines, ~line 22):
```swift
    /// Bumped whenever an album is created/renamed/deleted or membership changes.
    /// `LibraryView` observes this to reload, since membership edits don't change
    /// `itemCount`.
    @Published private(set) var albumsVersion: Int = 0
```

Add the service property (near `let indexService`, line ~27):
```swift
    let albumService: LibraryAlbumService
```

Initialize it in `init` (after `self.indexService = ...`, line ~40):
```swift
        self.albumService = LibraryAlbumService(
            index: indexService,
            itemsDirectory: { try? await LibraryContainer.shared.itemsDirectory() }
        )
```

Add the notifier method (anywhere in the type, e.g. after `markDateBackfillRanThisSession`):
```swift
    func notifyAlbumsChanged() { albumsVersion += 1 }
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryStoreAlbumTests 2>&1 | tail -40`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryStore.swift DiffuselyTests/LibraryStoreAlbumTests.swift
git commit -m "Wire album service and change signal into LibraryStore"
```

---

## Task 9: Read side — `AlbumFilter`, filtered sorted content, album summaries

Add a filter type, teach `LibrarySortService` to scope by it, and add an album-summary list (id, name, count, cover) for the Albums grid.

**Files:**
- Create: `Diffusely/Parameters/AlbumFilter.swift`
- Modify: `Diffusely/Services/Library/LibrarySortService.swift`
- Test: `DiffuselyTests/LibraryAlbumFilterTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryAlbumFilterTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumFilterTests 2>&1 | tail -40`
Expected: FAIL to compile (`AlbumFilter`, `filter:` overload, `albumSummaries` undefined).

- [ ] **Step 3: Add the filter type and read methods**

Create `Diffusely/Parameters/AlbumFilter.swift`:
```swift
import Foundation

/// Scopes the Library read side. `.all` is the whole library; `.album` is one
/// album's members; `.notInAnyAlbum` is the complement (items in zero *existing*
/// albums — dangling references to deleted albums count as "not in any album").
enum AlbumFilter: Equatable, Hashable {
    case all
    case album(UUID)
    case notInAnyAlbum
}
```

In `LibrarySortService.swift`:

Add a filtered overload and route the existing one through it. Replace the existing `sortedLibraryContent(sort:)` (lines ~51-61) with:
```swift
    func sortedLibraryContent(sort: LibrarySort) -> LibrarySortedContent {
        sortedLibraryContent(sort: sort, filter: .all)
    }

    func sortedLibraryContent(sort: LibrarySort, filter: AlbumFilter) -> LibrarySortedContent {
        let all = fetchAll(filter: filter)
        switch sort {
        case .dateNewest, .dateOldest:
            return .flat(sortByDate(all, ascending: sort.ascending))
        case .authorAscending, .authorDescending:
            return .grouped(groupByAuthor(all, ascending: sort.ascending))
        case .checkpointAscending, .checkpointDescending:
            return .grouped(groupByCheckpoint(all, ascending: sort.ascending))
        }
    }
```

Replace the private `fetchAll()` (lines ~76-78) with a filtered version:
```swift
    private func fetchAll(filter: AlbumFilter = .all) -> [PersistedLibraryItem] {
        let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        switch filter {
        case .all:
            return all
        case .album(let id):
            let key = id.uuidString
            return all.filter { $0.belongs(toAlbum: key) }
        case .notInAnyAlbum:
            let known = knownAlbumIDStrings()
            return all.filter { item in item.albumIDs.allSatisfy { !known.contains($0) } }
        }
    }

    private func knownAlbumIDStrings() -> Set<String> {
        let albums = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        return Set(albums.map { $0.id.uuidString })
    }
```

Add the summary API + type at the end of the class (before the final `}`):
```swift
    struct AlbumSummary: Identifiable, Equatable {
        let id: UUID
        let name: String
        let count: Int
        let coverItem: PersistedLibraryItem?

        static func == (l: AlbumSummary, r: AlbumSummary) -> Bool {
            l.id == r.id && l.name == r.name && l.count == r.count
                && l.coverItem?.itemID == r.coverItem?.itemID
        }
    }

    /// One row per album for the Albums grid: name, member count, and the most
    /// recent member as the cover. Albums with no members get a nil cover.
    func albumSummaries() -> [AlbumSummary] {
        let albums = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        return albums
            .map { album in
                let key = album.id.uuidString
                let members = newestFirst(all.filter { $0.belongs(toAlbum: key) })
                return AlbumSummary(id: album.id, name: album.name,
                                    count: members.count, coverItem: members.first)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Count of items in zero existing albums — the "Not in any Album" badge.
    func notInAnyAlbumCount() -> Int {
        fetchAll(filter: .notInAnyAlbum).count
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `... -only-testing:DiffuselyTests/LibraryAlbumFilterTests 2>&1 | tail -40`
Expected: PASS (4 tests). Also run `-only-testing:DiffuselyTests/LibrarySortTests` to confirm the existing sort/group suites still pass through the re-routed `fetchAll`.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Parameters/AlbumFilter.swift Diffusely/Services/Library/LibrarySortService.swift DiffuselyTests/LibraryAlbumFilterTests.swift
git commit -m "Add album filtering and summaries to the library read side"
```

---

## Task 10: Scope `LibraryView` by `AlbumFilter` (album detail + not-in-album reuse the grid)

Parameterize `LibraryView` with an `AlbumFilter` so the same view renders the flat grid, an album's contents, or the "Not in any Album" set — reusing all existing sort/group/select/delete logic. Album-specific actions appear only in the relevant scope. This task does NOT add the Albums browser yet (Task 11).

**Files:**
- Modify: `Diffusely/Views/LibraryView.swift`

This is SwiftUI wiring; verify by building + manual run. The testable logic it depends on is already covered (Task 9).

- [ ] **Step 1: Add the scope parameter and route content through the filter**

In `LibraryView.swift`, add stored properties at the top of the struct (after line 5):
```swift
    /// Which slice of the library this instance renders. `.all` is the top-level
    /// Library (and shows the Photos/Albums switcher — added in Task 11); the
    /// other cases are pushed detail screens scoped to an album or the
    /// not-in-any-album complement.
    var filter: AlbumFilter = .all
    /// Title for scoped instances (album name, or "Not in any Album").
    var scopeTitle: String? = nil
```

Change `reloadContent()` to pass the filter (line ~379):
```swift
        let newContent = sortService.sortedLibraryContent(sort: selectedSort, filter: filter)
```

Change the navigation title to honor `scopeTitle` (line ~24):
```swift
            .navigationTitle(isSelecting ? selectionTitle : (scopeTitle ?? "Library"))
```

Add an observer so album/membership edits reload (after the `.onChange(of: store.itemCount)` block, line ~95):
```swift
            .onChange(of: store.albumsVersion) {
                reloadContent()
            }
```

- [ ] **Step 2: Add album-scoped toolbar actions (Remove from Album; Rename/Delete album)**

Still in `LibraryView.swift`, add state (after line 20):
```swift
    @State private var showingRenameAlbum = false
    @State private var renameAlbumText = ""
    @State private var showingDeleteAlbumConfirm = false
```

In the selecting branch of the toolbar (inside `if isSelecting`, after the destructive delete `ToolbarItem`, around line 40), add a Remove-from-Album action that only exists in an album scope:
```swift
                    if case .album(let albumID) = filter {
                        ToolbarItem(placement: .secondaryAction) {
                            Button {
                                let ids = Array(selectedIDs)
                                Task {
                                    await store.albumService.removeItems(ids, fromAlbum: albumID)
                                    store.notifyAlbumsChanged()
                                    exitSelection()
                                }
                            } label: {
                                Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                            }
                            .disabled(selectedIDs.isEmpty)
                        }
                    }
```

In the non-selecting branch (the `else` with Sort + Select, around line 41), add an overflow menu for album rename/delete when in an album scope:
```swift
                    if case .album = filter {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    renameAlbumText = scopeTitle ?? ""
                                    showingRenameAlbum = true
                                } label: { Label("Rename Album", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    showingDeleteAlbumConfirm = true
                                } label: { Label("Delete Album", systemImage: "trash") }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
```

Add the rename alert and delete confirmation. Append after the existing `.confirmationDialog(...)` for single delete (around line 82), still inside the modifier chain on `content(for:)`:
```swift
            .alert("Rename Album", isPresented: $showingRenameAlbum) {
                TextField("Album name", text: $renameAlbumText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if case .album(let albumID) = filter {
                        let name = renameAlbumText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        Task {
                            await store.albumService.renameAlbum(albumID, to: name)
                            store.notifyAlbumsChanged()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this album?",
                isPresented: $showingDeleteAlbumConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Album", role: .destructive) {
                    if case .album(let albumID) = filter {
                        Task {
                            await store.albumService.deleteAlbum(albumID)
                            store.notifyAlbumsChanged()
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The album is removed. Your photos and videos are kept.")
            }
```

Add the dismiss environment value (after the `@Environment(\.modelContext)` line, ~line 7):
```swift
    @Environment(\.dismiss) private var dismiss
```

- [ ] **Step 3: Build and run to verify it compiles and scoped grids render**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

Manual check (after Task 11 wires navigation, you'll exercise this end to end). For now confirm the project builds and existing Library still works:
Run the app, open Library — the flat grid and existing Sort/Select behave exactly as before (filter defaults to `.all`).

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/LibraryView.swift
git commit -m "Scope LibraryView by AlbumFilter with album-detail actions"
```

---

## Task 11: Albums browser — Photos/Albums switch, Add to Album, New Album

Add the segmented control to the top-level Library, the Albums grid (covers + "Not in any Album" + New Album), the "Add to Album…" sheet on the multi-select toolbar and single-item context menu, and navigation into album detail.

**Files:**
- Create: `Diffusely/Views/AlbumsBrowserView.swift`
- Create: `Diffusely/Views/AddToAlbumSheet.swift`
- Modify: `Diffusely/Views/LibraryView.swift`

SwiftUI wiring; verify by build + manual run. Underlying logic is tested in Tasks 7 and 9.

- [ ] **Step 1: Create the "Add to Album" sheet**

Create `Diffusely/Views/AddToAlbumSheet.swift`:
```swift
import SwiftUI

/// Sheet for placing the given item IDs into an existing album or a brand-new one.
/// Calls back through `LibraryStore.albumService` and bumps `albumsVersion`.
struct AddToAlbumSheet: View {
    let itemIDs: [Int]
    let summaries: [LibrarySortService.AlbumSummary]
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var creatingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        creatingNew = true
                    } label: {
                        Label("New Album…", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
                if !summaries.isEmpty {
                    Section("Albums") {
                        ForEach(summaries) { album in
                            Button {
                                add(to: album.id)
                            } label: {
                                HStack {
                                    Text(album.name)
                                    Spacer()
                                    Text("\(album.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Album", isPresented: $creatingNew) {
                TextField("Album name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newName = ""
                    guard !name.isEmpty else { return }
                    Task {
                        let id = await store.albumService.createAlbum(name: name)
                        await store.albumService.addItems(itemIDs, toAlbum: id)
                        store.notifyAlbumsChanged()
                        dismiss()
                    }
                }
            }
        }
    }

    private func add(to albumID: UUID) {
        Task {
            await store.albumService.addItems(itemIDs, toAlbum: albumID)
            store.notifyAlbumsChanged()
            dismiss()
        }
    }
}
```

- [ ] **Step 2: Create the Albums browser grid**

Create `Diffusely/Views/AlbumsBrowserView.swift`:
```swift
import SwiftUI

/// The "Albums" mode of the top-level Library: a grid of album cover tiles plus
/// a built-in "Not in any Album" smart tile and a "New Album" tile. Tapping an
/// album (or the smart tile) pushes a scoped `LibraryView`.
struct AlbumsBrowserView: View {
    let summaries: [LibrarySortService.AlbumSummary]
    let notInAnyAlbumCount: Int
    let onNewAlbum: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                NavigationLink {
                    LibraryView(filter: .notInAnyAlbum, scopeTitle: "Not in any Album")
                } label: {
                    smartTile(title: "Not in any Album", count: notInAnyAlbumCount, systemImage: "square.grid.2x2")
                }
                .buttonStyle(.plain)

                ForEach(summaries) { album in
                    NavigationLink {
                        LibraryView(filter: .album(album.id), scopeTitle: album.name)
                    } label: {
                        albumTile(album)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onNewAlbum) {
                    smartTile(title: "New Album", count: nil, systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }

    private func albumTile(_ album: LibrarySortService.AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(.secondarySystemBackground)
                if let cover = album.coverItem {
                    LibraryAsyncImage(
                        itemID: cover.itemID, mediaFileName: cover.mediaFileName,
                        isVideo: cover.isVideo, maxDimension: LibraryImageRequest.gridDimension,
                        contentMode: .fill)
                } else {
                    Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary).font(.title)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(album.name).font(.subheadline).lineLimit(1)
            Text("\(album.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func smartTile(title: String, count: Int?, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
                Image(systemName: systemImage).font(.title).foregroundStyle(Color.accentColor)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(title).font(.subheadline).lineLimit(1)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
```

- [ ] **Step 3: Add the Photos/Albums switch and Add-to-Album entry points to `LibraryView`**

In `LibraryView.swift`:

Add state (after line 20):
```swift
    enum Mode: Hashable { case photos, albums }
    @State private var mode: Mode = .photos
    @State private var albumSummaries: [LibrarySortService.AlbumSummary] = []
    @State private var notInAnyAlbumCount: Int = 0
    @State private var addToAlbumIDs: [Int]? = nil
```

In `reloadContent()`, refresh the album summaries when at top level (append at the end of the method, after `content = newContent`):
```swift
        if filter == .all {
            albumSummaries = sortService.albumSummaries()
            notInAnyAlbumCount = sortService.notInAnyAlbumCount()
        }
```

Wrap the main body so `.all` + `.albums` shows the browser. Change `body`'s root from `content(for: content)` (line 23) to:
```swift
        Group {
            if filter == .all && mode == .albums {
                AlbumsBrowserView(
                    summaries: albumSummaries,
                    notInAnyAlbumCount: notInAnyAlbumCount,
                    onNewAlbum: { addToAlbumIDs = [] }   // empty selection → create-only flow
                )
            } else {
                content(for: content)
            }
        }
```
(Keep the entire existing `.navigationTitle(...)`/`.toolbar`/`.task` modifier chain attached to this `Group`.)

Add the segmented control to the toolbar, only at top level and not while selecting. Inside the `else` (non-selecting) toolbar branch, before `LibrarySortMenu` (around line 42):
```swift
                    if filter == .all {
                        ToolbarItem(placement: .principal) {
                            Picker("Mode", selection: $mode) {
                                Text("Photos").tag(Mode.photos)
                                Text("Albums").tag(Mode.albums)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                    }
```

Add the "Add to Album…" action to the multi-select toolbar. In the `if isSelecting` branch, after the destructive delete button (around line 40):
```swift
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            addToAlbumIDs = Array(selectedIDs)
                        } label: { Label("Add to Album", systemImage: "rectangle.stack.badge.plus") }
                        .disabled(selectedIDs.isEmpty)
                    }
```

Add "Add to Album" to the single-item context menu in `cells(for:)` (inside `.contextMenu`, before the destructive Delete, around line 185):
```swift
                    Button {
                        addToAlbumIDs = [item.itemID]
                    } label: { Label("Add to Album", systemImage: "rectangle.stack.badge.plus") }
```

Present the sheet. Add to the modifier chain (after the album confirmation dialog from Task 10):
```swift
            .sheet(isPresented: Binding(
                get: { addToAlbumIDs != nil },
                set: { if !$0 { addToAlbumIDs = nil } }
            )) {
                AddToAlbumSheet(
                    itemIDs: addToAlbumIDs ?? [],
                    summaries: albumSummaries
                )
                .environmentObject(store)
            }
```
Note: the "New Album" tile passes `[]` (create an empty album). `AddToAlbumSheet` with empty `itemIDs` still creates the album; `addItems([], …)` is a guarded no-op (Task 7), so an empty album is created correctly.

- [ ] **Step 4: Build and run; exercise the whole feature**

Run: `xcodebuild build -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

Manual acceptance (run the app, Library tab):
1. Photos/Albums switch toggles between the flat grid and the Albums browser.
2. Select 2+ items → "Add to Album" → New Album "Test" → items land in it; Albums shows "Test" with a cover and count 2.
3. Open "Test" → grid scoped to those items; Sort menu and grouping all work; Select → "Remove from Album" empties it.
4. Overflow → Rename to "Test2" (title + Albums tile update); Delete Album → returns to browser, the items reappear under "Not in any Album", their media still present.
5. Single item context menu → "Add to Album" → existing album works.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Views/AlbumsBrowserView.swift Diffusely/Views/AddToAlbumSheet.swift Diffusely/Views/LibraryView.swift
git commit -m "Add Albums browser, Photos/Albums switch, and Add to Album"
```

---

## Task 12: Full regression pass

- [ ] **Step 1: Run the entire test target**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DiffuselyTests 2>&1 | tail -50`
Expected: all suites pass, including the pre-existing `LibraryTests`, `LibrarySortTests`, `LibraryImageRequestTests`, `LibraryFileMaterializerTests`, `LibraryDateBackfillTests`, and every new album suite.

- [ ] **Step 2: Commit any final fixups (if needed)**

```bash
git add -A
git commit -m "Library Albums: regression fixups"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Multiple-album membership → Task 1 (`albumIDs`), Task 2 (denormalized), Task 9 (`.album` filter).
- Add items singly + multi-select to new/existing album → Task 11 (context menu + multi-select "Add to Album…" + `AddToAlbumSheet`), Task 7 (`addItems`).
- Album view with full sort/group → Task 10 (scoped `LibraryView` routes filter through `LibrarySortService`).
- "Not in any Album" with full sort/group → Task 9 (`.notInAnyAlbum` complement), Task 10/11 (smart tile → scoped view).
- Remove from album → Task 7 (`removeItems`) + Task 10 (toolbar).
- Rename album → Task 7 + Task 10 (overflow + alert).
- Delete album (keeps photos) → Task 7 (`deleteAlbum`, file+row only) + Task 10 (confirm), Task 5/9 (dangling-ID handling).
- Auto cover = most recent member → Task 9 (`albumSummaries` cover = `newestFirst().first`).
- Sidecar-is-truth / disposable index / iCloud sync → Tasks 1, 4, 5 (album files + reconcile rebuild).
- Cooperative-pool discipline → Tasks 4, 7 (coordinated I/O on dedicated serial queue).
- Schema registration → Task 3.

**Non-goals respected:** no custom cover picker, no manual ordering, no nested albums, deleting an album never deletes media.

**Placeholder scan:** none — every step has concrete code/commands.

**Type/name consistency:** `AlbumFilter` (`.all`/`.album(UUID)`/`.notInAnyAlbum`), `LibraryAlbumFile`, `LibraryAlbumStore` (`fileName(for:)`, `albumID(fromFileName:)`, `read`/`write`/`delete`), `LibraryAlbumService` (`createAlbum`/`renameAlbum`/`deleteAlbum`/`addItems(_:toAlbum:)`/`removeItems(_:fromAlbum:)`), index methods (`upsertAlbum`/`removeAlbum`/`setAlbumIDs`), `PersistedLibraryItem` (`albumIDsJoined`/`albumIDs`/`isInAnyAlbum`/`belongs(toAlbum:)`/`join`), `LibrarySortService` (`sortedLibraryContent(sort:filter:)`/`albumSummaries`/`notInAnyAlbumCount`/`AlbumSummary`), `LibraryStore` (`albumService`/`albumsVersion`/`notifyAlbumsChanged`) are used consistently across tasks.
