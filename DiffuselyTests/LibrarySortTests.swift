import Testing
import Foundation
import SwiftData
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

// MARK: - Helpers for upcoming sort/group suites in this file

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

@Suite final class LibrarySortServiceTests {
    // Held strongly so its `mainContext` doesn't dangle inside test bodies.
    private var container: ModelContainer?

    @MainActor
    private func makeService() throws -> (LibrarySortService, ModelContext) {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        self.container = container
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
