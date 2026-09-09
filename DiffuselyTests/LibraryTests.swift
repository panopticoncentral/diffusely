import Testing
import Foundation
import CryptoKit
import SwiftData
@testable import Diffusely

/// Shared across `DiffuselyTests` (not just this file) as the standard way to
/// build a `LibraryItemMetadata` fixture with sane defaults.
func makeMetadata(
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

@Suite struct LibraryMetadataTests {
    @Test func roundTripsIncludingSchemaVersionAndNilGenerationData() throws {
        let original = makeMetadata(itemID: 100, generationData: nil)
        let data = try LibraryItemMetadata.encoder().encode(original)
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.itemID == 100)
        #expect(decoded.schemaVersion == LibraryItemMetadata.currentSchemaVersion)
        #expect(decoded.generationData == nil)
        #expect(decoded.canonicalPageURL == "https://civitai.com/images/100")
        #expect(decoded.mediaFileName == "100.jpeg")
    }

    @Test func roundTripsPostFields() throws {
        let original = makeMetadata(itemID: 300, sourcePostTitle: "Sunset set", canonicalPostURL: "https://civitai.com/posts/42")
        let data = try LibraryItemMetadata.encoder().encode(original)
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.sourcePostID == 42)
        #expect(decoded.sourcePostTitle == "Sunset set")
        #expect(decoded.canonicalPostURL == "https://civitai.com/posts/42")
    }

    @Test func decodesLegacyV1JSONMissingPostFields() throws {
        // A schemaVersion-1 sidecar written before post fields existed: the new
        // optional keys are absent and must decode as nil (rebuildable index).
        let legacy = """
        {
            "schemaVersion": 1,
            "itemID": 999,
            "sourcePostID": 5,
            "canonicalPageURL": "https://civitai.com/images/999",
            "sourceDomain": "civitai.com",
            "originalCDNURL": "https://image.civitai.com/x/u/original=true/999.jpeg",
            "mediaType": "image",
            "mediaFileName": "999.jpeg",
            "fileByteSize": 10,
            "contentSHA256": "ab",
            "width": 1, "height": 1, "nsfwLevel": 1,
            "author": {},
            "savedAt": "2026-01-01T00:00:00Z",
            "savedByAppVersion": "old"
        }
        """.data(using: .utf8)!
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: legacy)
        #expect(decoded.itemID == 999)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.sourcePostTitle == nil)
        #expect(decoded.canonicalPostURL == nil)
        #expect(decoded.generationData == nil)
    }

    @Test func roundTripsWithGenerationData() throws {
        let gen = GenerationData(
            type: "image",
            meta: GenerationMeta(prompt: "a cat", negativePrompt: nil, cfgScale: 7, steps: 20, sampler: "Euler", seed: 1, clipSkip: 2),
            resources: [GenerationResource(modelId: 1, modelName: "M", modelType: "Checkpoint", versionId: 2, versionName: "v1", strength: 0.8)]
        )
        let data = try LibraryItemMetadata.encoder().encode(makeMetadata(itemID: 101, generationData: gen))
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.generationData?.meta?.prompt == "a cat")
        #expect(decoded.generationData?.resources?.first?.modelName == "M")
    }

    @Test func currentSchemaVersionIsSix() {
        // v6 added generationDataBackfillAttemptedAt (the checkpoint backfill's
        // "Civitai confirmed it has nothing" stamp) on top of v5's albumIDs,
        // v4's publishedAtBackfillAttemptedAt and v3's publishedAt.
        #expect(LibraryItemMetadata.currentSchemaVersion == 6)
    }

    @Test func decodesV3JSONMissingBackfillMarkerAsNil() throws {
        // A v3 sidecar (publishedAt present, marker absent) must decode with
        // publishedAtBackfillAttemptedAt == nil. Adding the new field is a
        // non-breaking optional addition — sidecars synced from devices on
        // older app versions must still load.
        let legacy = """
        {
            "schemaVersion": 3,
            "itemID": 800,
            "sourcePostID": null,
            "sourcePostTitle": null,
            "canonicalPostURL": null,
            "canonicalPageURL": "https://civitai.com/images/800",
            "sourceDomain": "civitai.com",
            "originalCDNURL": "https://image.civitai.com/x/u/original=true/800.jpeg",
            "mediaType": "image",
            "mediaFileName": "800.jpeg",
            "fileByteSize": 0,
            "contentSHA256": "x",
            "width": 1, "height": 1, "nsfwLevel": 1,
            "author": { "id": null, "username": null, "avatarURL": null },
            "stats": null,
            "generationData": null,
            "publishedAt": "2024-03-22T10:52:00Z",
            "savedAt": "2024-03-22T10:52:00Z",
            "savedByAppVersion": "old"
        }
        """.data(using: .utf8)!
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: legacy)
        #expect(decoded.itemID == 800)
        #expect(decoded.publishedAt != nil)
        #expect(decoded.publishedAtBackfillAttemptedAt == nil)
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
}

@Suite struct CivitaiImageOriginalURLTests {
    @Test func buildsFromRawUUID() {
        let image = CivitaiImage(
            id: 555, url: "raw-uuid-123", width: 10, height: 10,
            nsfwLevel: 1, type: "image", postId: nil, user: nil, stats: nil
        )
        #expect(image.originalURL == "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/raw-uuid-123/original=true/555.jpeg")
    }

    @Test func buildsFromFullPersistedURL() {
        let full = "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/the-uuid/anim=false,width=450/555.jpeg"
        let image = CivitaiImage(
            id: 555, url: full, width: 10, height: 10,
            nsfwLevel: 1, type: "image", postId: nil, user: nil, stats: nil
        )
        #expect(image.originalURL == "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/the-uuid/original=true/555.jpeg")
    }

    @Test func videoUsesMp4Extension() {
        let image = CivitaiImage(
            id: 9, url: "vid-uuid", width: 10, height: 10,
            nsfwLevel: 1, type: "video", postId: nil, user: nil, stats: nil
        )
        #expect(image.originalURL.hasSuffix("/vid-uuid/original=true/9.mp4"))
    }
}

@Suite struct LibraryFileWriterTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func commitWritesMediaAndJSONWithCorrectNames() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LibraryFileWriter(itemsDirectory: dir)

        let tempMedia = dir.appendingPathComponent("download.tmp")
        try Data("bytes".utf8).write(to: tempMedia)

        let metadata = makeMetadata(itemID: 200)
        #expect(writer.itemExists(itemID: 200) == false)
        try writer.commit(metadata: metadata, mediaTempURL: tempMedia)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("200.jpeg").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("200.json").path))
        #expect(writer.itemExists(itemID: 200))

        let json = try Data(contentsOf: dir.appendingPathComponent("200.json"))
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: json)
        #expect(decoded.itemID == 200)
    }

    @Test func commitWithMissingMediaTempDoesNotWriteJSON() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let missing = dir.appendingPathComponent("nope.tmp")

        #expect(throws: (any Error).self) {
            try writer.commit(metadata: makeMetadata(itemID: 201), mediaTempURL: missing)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("201.json").path) == false)
    }

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
}

@Suite struct LibraryIndexReconcileTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func reconcileIngestsSidecarsAndIgnoresMediaWithoutJSON() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Item 1: full JSON + media.
        let m1 = makeMetadata(itemID: 1)
        try LibraryItemMetadata.encoder().encode(m1).write(to: dir.appendingPathComponent("1.json"))
        try Data("img".utf8).write(to: dir.appendingPathComponent("1.jpeg"))
        // Item 2: media only, no JSON -> must be ignored.
        try Data("img".utf8).write(to: dir.appendingPathComponent("2.jpeg"))

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir)

        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(items.count == 1)
        #expect(items.first?.itemID == 1)
    }

    @Test func reconcileDropsRowsWhoseSidecarVanished() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        let m = makeMetadata(itemID: 5)
        try LibraryItemMetadata.encoder().encode(m).write(to: dir.appendingPathComponent("5.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("5.jpeg"))
        await index.reconcile(itemsDirectory: dir)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("5.json"))
        await index.reconcile(itemsDirectory: dir)

        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(items.isEmpty)
    }

    @Test func sidecarItemIDParsesFilenameStem() {
        // The no-prune-on-placeholder path recovers the item ID from the sidecar
        // filename (without reading the file). If this contract breaks, a skipped
        // placeholder would be pruned as "vanished".
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LibraryIndexService.sidecarItemID(from: dir.appendingPathComponent("42.json")) == 42)
        #expect(LibraryIndexService.sidecarItemID(from: dir.appendingPathComponent("not-a-number.json")) == nil)
    }

    @Test func nonUbiquitousLocalSidecarIsNotTreatedAsPlaceholder() {
        // A plain local file (no iCloud) must read normally — isDatalessPlaceholder
        // only skips un-materialized ubiquitous items.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("7.json")
        try? Data("{}".utf8).write(to: url)
        #expect(LibraryIndexService.isDatalessPlaceholder(url) == false)
    }

    @Test func wipeDeletesAllRowsAndItemCountTracksThem() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        #expect(await index.itemCount() == 0)
        await index.ingest(metadata: makeMetadata(itemID: 1), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 2), downloadStatus: .downloaded)
        #expect(await index.itemCount() == 2)

        await index.wipe()

        #expect(await index.itemCount() == 0)
        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(items.isEmpty)
    }

    @Test func enforceCacheLimitEvictsLeastRecentlyAccessedFirst() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        let now = Date()
        // Oldest access first; each 100 bytes; cap 150 -> must evict the two oldest.
        await index.ingest(metadata: makeMetadata(itemID: 1, byteSize: 100, savedAt: now.addingTimeInterval(-300)), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 2, byteSize: 100, savedAt: now.addingTimeInterval(-200)), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 3, byteSize: 100, savedAt: now.addingTimeInterval(-100)), downloadStatus: .downloaded)

        await index.enforceCacheLimit(maxBytes: 150, itemsDirectory: dir)

        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0.downloadStatus) })
        #expect(byID[1] == .evicted)
        #expect(byID[2] == .evicted)
        #expect(byID[3] == .downloaded)
    }

    // Not @MainActor on purpose: proves the coordinated eviction runs off the
    // main actor (its reason for existing — keep blocking iCloud eviction I/O,
    // an XPC round-trip to fileproviderd, off the cooperative pool / main
    // thread). `evictUbiquitousItem` is an iCloud op, so on a plain
    // non-ubiquitous temp file it does not remove the file; we assert the
    // helper completes and tolerates a mix of present and missing files.
    @Test func runEvictMediaCompletesOffMainActorAndToleratesMissing() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("img".utf8).write(to: dir.appendingPathComponent("1.jpeg"))
        // "2.mp4" intentionally absent — the helper must tolerate it.

        await LibraryIndexService.runEvictMedia(
            victims: [(itemID: 1, plaintextExtension: "jpeg"), (itemID: 2, plaintextExtension: "mp4")],
            store: LibraryFileStore(itemsDirectory: dir, crypto: nil)
        )

        // Reaching here proves the coordinated eviction completed off the main
        // actor. The present file remains: eviction is an iCloud op, not a
        // local delete, so a plain temp file is untouched.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path))
    }
}

/// Session-scoped flags on `LibraryStore` — currently the date-backfill gate.
/// Lives on `LibraryStore` (not `@State` on a view) so navigating into and out
/// of the Library tab does not re-trigger backfill, which was making the
/// "Backfilling publish dates…" spinner appear every time.
@Suite struct LibraryStoreSessionStateTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @MainActor @Test func dateBackfillSessionFlagStartsFalseAndCanBeMarked() async throws {
        let container = try makeContainer()
        let store = LibraryStore(modelContainer: container)

        #expect(store.didRunDateBackfillThisSession == false)

        store.markDateBackfillRanThisSession()

        #expect(store.didRunDateBackfillThisSession == true)
    }
}

@Suite struct LibraryBatchRemovalTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor @Test func deleteItemFilesRemovesAllExtensionsForListedIDs() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Item 1: json + jpeg. Item 2: json + mp4. Item 3: untouched survivor.
        try Data("a".utf8).write(to: dir.appendingPathComponent("1.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("1.jpeg"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("2.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("2.mp4"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("3.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("3.jpeg"))

        LibraryStore.deleteItemFiles(itemIDs: [1, 2], in: dir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("2.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("2.mp4").path) == false)
        // Survivor untouched.
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("3.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("3.jpeg").path))
    }

    @MainActor @Test func deleteItemFilesToleratesMissingFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Only the json exists; jpeg/mp4 absent. Must not throw.
        try Data("a".utf8).write(to: dir.appendingPathComponent("5.json"))

        LibraryStore.deleteItemFiles(itemIDs: [5], in: dir)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("5.json").path) == false)
    }

    @Test func deleteFilesRemovesListedURLsAndToleratesMissing() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appendingPathComponent("present.json")
        let absent = dir.appendingPathComponent("absent.json")
        try Data("a".utf8).write(to: present)

        // Mixed list of an existing and a missing URL must not throw.
        LibraryStore.deleteFiles(at: [present, absent])

        #expect(FileManager.default.fileExists(atPath: present.path) == false)
    }

    // Not @MainActor on purpose: proves the coordinated delete runs off the
    // main actor (its whole reason for existing — keep blocking iCloud I/O off
    // the cooperative pool / main thread).
    @Test func runDeleteItemFilesDeletesAllExtensionsOffMainActor() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("7.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("7.jpeg"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("8.json"))

        await LibraryStore.runDeleteItemFiles(itemIDs: [7], in: dir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("7.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("7.jpeg").path) == false)
        // Untouched survivor.
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("8.json").path))
    }


    /// Reset must clear the Library without touching anything the app did not
    /// write. At a custom root the items directory IS the user's own folder, so
    /// a blanket sweep would destroy unrelated files.
    @Test func resetDeletesOnlyFilesDiffuselyWrote() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        // Diffusely's: one item (sidecar + media) and one album file.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("1.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("1.jpeg"))
        let albumName = LibraryAlbumStore.fileName(for: UUID())
        try Data("{}".utf8).write(to: dir.appendingPathComponent(albumName))

        // The user's own file, sitting in the same folder.
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        _ = await LibraryStore.deleteAppWrittenFiles(in: dir, store: store)

        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(albumName).path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }

    /// The user's own files, an orphaned media file with no sidecar, and any
    /// subdirectory must all survive, and the count reported back must match
    /// what is actually left so the UI cannot claim a cleaner sweep than happened.
    @Test func resetKeepsForeignFilesOrphansAndDirectoriesAndCountsThem() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        try Data("{}".utf8).write(to: dir.appendingPathComponent("1.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("1.jpeg"))
        // Media whose sidecar is already gone. Indistinguishable from a photo of
        // the user's that happens to have a numeric name, so it stays.
        try Data("a".utf8).write(to: dir.appendingPathComponent("9999.jpeg"))
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("Screenshots", isDirectory: true),
                               withIntermediateDirectories: true)

        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let kept = await LibraryStore.deleteAppWrittenFiles(in: dir, store: store)

        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("9999.jpeg").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("Screenshots").path))
        #expect(kept == 3)
    }

    /// The encrypted container is the case that would silently do nothing if the
    /// sweep matched plaintext names: every file there has an opaque HMAC stem
    /// and only its `.m` / `.b` / `.x` role extension to go on.
    @Test func resetDeletesOpaqueEncryptedFilesButNotForeignOnes() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(Data(#"{"itemID":1}"#.utf8), itemID: 1)
        try store.writeMedia(Data("a".utf8), itemID: 1, plaintextExtension: "jpeg")
        try store.writeAux(Data("{}".utf8), name: LibraryAlbumStore.fileName(for: UUID()))
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let kept = await LibraryStore.deleteAppWrittenFiles(in: dir, store: store)

        let remaining = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        #expect(remaining == ["notes.txt"])
        #expect(kept == 1)
    }

    @Test func removeItemIDsDeletesListedRowsAndLeavesOthers() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        await index.ingest(metadata: makeMetadata(itemID: 1), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 2), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 3), downloadStatus: .downloaded)
        #expect(await index.itemCount() == 3)

        await index.remove(itemIDs: [1, 3])

        #expect(await index.itemCount() == 1)
        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(items.map(\.itemID) == [2])
    }

    @Test func removeItemIDsEmptyListIsNoOp() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.ingest(metadata: makeMetadata(itemID: 9), downloadStatus: .downloaded)

        await index.remove(itemIDs: [])

        #expect(await index.itemCount() == 1)
    }

    @Test func removeItemIDsIgnoresUnknownIDs() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.ingest(metadata: makeMetadata(itemID: 1), downloadStatus: .downloaded)

        await index.remove(itemIDs: [1, 999])

        #expect(await index.itemCount() == 0)
    }
}
