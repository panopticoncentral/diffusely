import Testing
import Foundation
import SwiftData
@testable import Diffusely

// MARK: - Helpers

private func makeMeta(
    itemID: Int,
    generationData: GenerationData? = nil,
    attemptedAt: Date? = nil,
    albumIDs: [String] = []
) -> LibraryItemMetadata {
    LibraryItemMetadata(
        schemaVersion: LibraryItemMetadata.currentSchemaVersion,
        itemID: itemID,
        sourcePostID: nil,
        sourcePostTitle: nil,
        canonicalPostURL: nil,
        canonicalPageURL: "https://civitai.com/images/\(itemID)",
        sourceDomain: "civitai.com",
        originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).jpeg",
        mediaType: .image,
        mediaFileName: "\(itemID).jpeg",
        fileByteSize: 1,
        contentSHA256: "x",
        width: 1, height: 1, nsfwLevel: 1,
        author: LibraryAuthor(id: 1, username: "alice", avatarURL: nil),
        stats: nil,
        generationData: generationData,
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        generationDataBackfillAttemptedAt: attemptedAt,
        albumIDs: albumIDs,
        savedAt: Date(timeIntervalSince1970: 1_700_000_000),
        savedByAppVersion: "t"
    )
}

private func genData(checkpoint: String?) -> GenerationData {
    var resources: [GenerationResource] = [
        GenerationResource(modelId: 9, modelName: "SomeLora", modelType: "LORA",
                           versionId: 1, versionName: "v1", strength: 1)
    ]
    if let checkpoint {
        resources.append(GenerationResource(modelId: 1, modelName: checkpoint, modelType: "Checkpoint",
                                            versionId: 1, versionName: "v1", strength: 1))
    }
    return GenerationData(type: "image", meta: nil, resources: resources)
}

/// Mimics `image.getGenerationData` returning `result.data.json == null` for a
/// deleted or unpublished image — the real service surfaces that as a decode
/// failure, which is how the backfill tells "Civitai has nothing" apart from
/// "the network is down".
private struct NoDataError: Error {}

private actor StubFetcher: LibraryCheckpointBackfillService.FetchGenerationDataProvider {
    enum Outcome {
        case success(GenerationData)
        case noData          // Civitai confirmed there is nothing
        case transient       // network/server failure
    }
    private let outcomes: [Int: Outcome]
    private(set) var requested: [Int] = []

    init(_ outcomes: [Int: Outcome]) { self.outcomes = outcomes }

    func fetchGenerationData(imageId: Int) async throws -> GenerationData {
        requested.append(imageId)
        switch outcomes[imageId] {
        case .success(let data): return data
        case .noData:
            throw DecodingError.valueNotFound(
                GenerationData.self,
                DecodingError.Context(codingPath: [], debugDescription: "json was null"))
        case .transient, .none: throw URLError(.timedOut)
        }
    }

    func requestedIDs() -> [Int] { requested }
}

private actor StubStore: LibraryCheckpointBackfillSidecarStore {
    private var pending: [LibraryItemMetadata]
    private(set) var written: [LibraryItemMetadata] = []
    private let failWritesFor: Set<Int>

    init(pending: [LibraryItemMetadata], failWritesFor: Set<Int> = []) {
        self.pending = pending
        self.failWritesFor = failWritesFor
    }

    func itemsMissingGenerationData() async throws -> [LibraryItemMetadata] { pending }

    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws {
        if failWritesFor.contains(metadata.itemID) { throw LibraryBackfillSidecarStoreError.vaultLocked }
        written.append(metadata)
    }

    func writtenMetadata() -> [LibraryItemMetadata] { written }
}

/// `cloudKitDatabase: .none` is load-bearing, not boilerplate: the default is
/// `.automatic`, and because the app ships the iCloud entitlement SwiftData
/// then attempts CloudKit mirroring, which fails the schema outright —
/// `PersistedLibraryItem` uses `@Attribute(.unique)`, which CloudKit forbids.
/// Omitting it crashes every test in this suite at container creation. Same
/// reason `DiffuselyApp.makeModelContainer` opts out.
private func makeIndexService() throws -> LibraryIndexService {
    let container = try ModelContainer(
        for: PersistedLibraryItem.self, PersistedAlbum.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    return LibraryIndexService(modelContainer: container)
}

// MARK: - Pending selection

@Suite struct CheckpointBackfillPendingTests {

    @Test func onlyItemsWithNoGenerationDataAtAllAreEligible() {
        // The measured reality: items that HAVE generation data but no
        // Checkpoint resource are not fixable by re-asking (0 of 50 sampled
        // gained one), so re-fetching them every session would be pure waste.
        #expect(PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: makeMeta(itemID: 1)))
        #expect(!PersistedLibraryItem.computeNeedsGenerationDataBackfill(
            for: makeMeta(itemID: 2, generationData: genData(checkpoint: nil))))
        #expect(!PersistedLibraryItem.computeNeedsGenerationDataBackfill(
            for: makeMeta(itemID: 3, generationData: genData(checkpoint: "Pony"))))
    }

    @Test func anAlreadyAttemptedItemIsNotEligibleAgain() {
        #expect(!PersistedLibraryItem.computeNeedsGenerationDataBackfill(
            for: makeMeta(itemID: 4, attemptedAt: Date())))
    }

    @Test func theIndexRowDenormalizesTheSameAnswer() {
        let row = PersistedLibraryItem(metadata: makeMeta(itemID: 5), downloadStatus: .downloaded)
        #expect(row.needsGenerationDataBackfill)
        let filled = PersistedLibraryItem(
            metadata: makeMeta(itemID: 6, generationData: genData(checkpoint: "Pony")),
            downloadStatus: .downloaded)
        #expect(!filled.needsGenerationDataBackfill)
    }
}

// MARK: - Run loop

@Suite @MainActor struct CheckpointBackfillRunTests {

    private func service(
        pending: [LibraryItemMetadata],
        outcomes: [Int: StubFetcher.Outcome],
        failWritesFor: Set<Int> = []
    ) throws -> (LibraryCheckpointBackfillService, StubStore, StubFetcher) {
        let store = StubStore(pending: pending, failWritesFor: failWritesFor)
        let fetcher = StubFetcher(outcomes)
        let service = LibraryCheckpointBackfillService(
            indexService: try makeIndexService(), sidecarStore: store, fetcher: fetcher)
        return (service, store, fetcher)
    }

    @Test func writesFetchedGenerationDataIntoTheSidecar() async throws {
        let (service, store, _) = try service(
            pending: [makeMeta(itemID: 1)],
            outcomes: [1: .success(genData(checkpoint: "Pony Diffusion V6 XL"))])
        await service.runOnce()

        let written = await store.writtenMetadata()
        #expect(written.count == 1)
        #expect(written.first?.generationData?.resources?.contains { $0.modelName == "Pony Diffusion V6 XL" } == true)
        // A successful fetch must NOT stamp the marker — the item is fixed,
        // and a stamp would wrongly read as "Civitai has nothing".
        #expect(written.first?.generationDataBackfillAttemptedAt == nil)
    }

    @Test func stampsTheMarkerWhenCivitaiConfirmsThereIsNothing() async throws {
        let (service, store, _) = try service(pending: [makeMeta(itemID: 2)], outcomes: [2: .noData])
        await service.runOnce()

        let written = await store.writtenMetadata()
        #expect(written.count == 1)
        #expect(written.first?.generationData == nil)
        #expect(written.first?.generationDataBackfillAttemptedAt != nil)
        // And that stamp must make it ineligible next session.
        #expect(!PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: written.first!))
    }

    @Test func leavesTransientFailuresAloneSoTheyRetryNextSession() async throws {
        // The distinction that matters: a timeout must not permanently mark an
        // item that Civitai may still have data for.
        let (service, store, _) = try service(pending: [makeMeta(itemID: 3)], outcomes: [3: .transient])
        await service.runOnce()

        #expect(await store.writtenMetadata().isEmpty)
    }

    @Test func oneBadItemDoesNotStopTheQueue() async throws {
        let (service, store, fetcher) = try service(
            pending: [makeMeta(itemID: 1), makeMeta(itemID: 2), makeMeta(itemID: 3)],
            outcomes: [1: .transient,
                       2: .success(genData(checkpoint: "Hassaku")),
                       3: .noData])
        await service.runOnce()

        #expect(await fetcher.requestedIDs() == [1, 2, 3])
        let written = await store.writtenMetadata().map(\.itemID)
        #expect(written == [2, 3])
    }

    @Test func aFailedSidecarWriteDoesNotStopTheQueue() async throws {
        let (service, store, _) = try service(
            pending: [makeMeta(itemID: 1), makeMeta(itemID: 2)],
            outcomes: [1: .success(genData(checkpoint: "A")), 2: .success(genData(checkpoint: "B"))],
            failWritesFor: [1])
        await service.runOnce()

        #expect(await store.writtenMetadata().map(\.itemID) == [2])
    }

    @Test func preservesEverythingElseInTheSidecar() async throws {
        // The bug this mirrors from the date backfill: albumIDs silently
        // defaulting to [] on rewrite wiped album membership.
        let (service, store, _) = try service(
            pending: [makeMeta(itemID: 7, albumIDs: ["A1", "A2"])],
            outcomes: [7: .success(genData(checkpoint: "Pony"))])
        await service.runOnce()

        let written = await store.writtenMetadata().first
        #expect(written?.albumIDs == ["A1", "A2"])
        #expect(written?.publishedAt != nil)
        #expect(written?.schemaVersion == LibraryItemMetadata.currentSchemaVersion)
    }

    @Test func updatesTheIndexRowSoTheItemLeavesTheOtherBucket() async throws {
        let indexService = try makeIndexService()
        let store = StubStore(pending: [makeMeta(itemID: 8)])
        let service = LibraryCheckpointBackfillService(
            indexService: indexService,
            sidecarStore: store,
            fetcher: StubFetcher([8: .success(genData(checkpoint: "Hassaku XL"))]))
        await indexService.ingest(metadata: makeMeta(itemID: 8), downloadStatus: .downloaded)

        await service.runOnce()

        let names = await indexService.checkpointIndexSnapshot().names
        #expect(names[8] == "Hassaku XL")
    }

    @Test func isIdempotentWhenNothingIsPending() async throws {
        let (service, store, fetcher) = try service(pending: [], outcomes: [:])
        await service.runOnce()
        #expect(await fetcher.requestedIDs().isEmpty)
        #expect(await store.writtenMetadata().isEmpty)
        #expect(service.remaining == 0)
    }

    @Test func reportsRemainingForTheProgressBanner() async throws {
        let (service, _, _) = try service(
            pending: [makeMeta(itemID: 1), makeMeta(itemID: 2)],
            outcomes: [1: .transient, 2: .transient])
        await service.runOnce()
        #expect(service.remaining == 0)
        #expect(!service.isRunning)
    }
}
