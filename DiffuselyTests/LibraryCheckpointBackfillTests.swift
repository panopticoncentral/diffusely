import Testing
import Foundation
import SwiftData
import CryptoKit
@testable import Diffusely

// MARK: - Helpers

private func makeMeta(
    itemID: Int,
    generationData: GenerationData? = nil,
    attemptedAt: Date? = nil,
    checkpointAttemptedAt: Date? = nil,
    checkpointProbePending: Bool = false,
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
        checkpointVersionLookupAttemptedAt: checkpointAttemptedAt,
        checkpointVersionProbePending: checkpointProbePending,
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

private func rawVersionData(_ id: Int = 290640) -> GenerationData {
    let prompt = """
    a portrait
    Negative prompt: blurry
    Steps: 30, Sampler: Euler a, Civitai resources: [{"type":"checkpoint","modelVersionId":\(id)},{"type":"lora","weight":1,"modelVersionId":215378}]
    """
    return GenerationData(
        type: "image",
        meta: GenerationMeta(prompt: prompt, negativePrompt: nil, cfgScale: 4,
                             steps: 30, sampler: "Euler a", seed: 123456, clipSkip: 2),
        resources: [GenerationResource(modelId: 2, modelName: "Style", modelType: "LORA",
                                       versionId: 215378, versionName: "v1", strength: 1)]
    )
}

private func ponyVersion() -> GenerationResource {
    GenerationResource(modelId: 257749, modelName: "Pony Diffusion V6 XL", modelType: "Checkpoint",
                       versionId: 290640, versionName: "V6", baseModel: "Pony", strength: nil)
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
    enum VersionOutcome {
        case resource(GenerationResource)
        case missing
        case notFound
        case transient
    }
    enum RawOutcome {
        case version(Int)
        case missing
        case notFound
        case transient
    }
    private let outcomes: [Int: Outcome]
    private let versionOutcomes: [Int: VersionOutcome]
    private let rawOutcomes: [Int: RawOutcome]
    private(set) var requested: [Int] = []
    private(set) var requestedVersions: [Int] = []
    private(set) var requestedRawIDs: [Int] = []

    init(_ outcomes: [Int: Outcome], versions: [Int: VersionOutcome] = [:], raw: [Int: RawOutcome] = [:]) {
        self.outcomes = outcomes
        self.versionOutcomes = versions
        self.rawOutcomes = raw
    }

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

    func fetchCheckpointVersion(versionId: Int) async throws -> GenerationResource? {
        requestedVersions.append(versionId)
        switch versionOutcomes[versionId] {
        case .resource(let resource): return resource
        case .missing: return nil
        case .notFound: throw HTTPStatusError(statusCode: 404)
        case .transient, .none: throw URLError(.timedOut)
        }
    }

    func requestedVersionIDs() -> [Int] { requestedVersions }

    func fetchRawCheckpointVersionID(imageId: Int) async throws -> Int? {
        requestedRawIDs.append(imageId)
        switch rawOutcomes[imageId] {
        case .version(let id): return id
        case .missing: return nil
        case .notFound: throw HTTPStatusError(statusCode: 404)
        case .transient, .none: throw URLError(.timedOut)
        }
    }

    func requestedRawImageIDs() -> [Int] { requestedRawIDs }
}

private actor StubStore: LibraryCheckpointBackfillSidecarStore {
    private var pending: [LibraryItemMetadata]
    private(set) var written: [LibraryItemMetadata] = []
    private let failWritesFor: Set<Int>
    private let embeddedVersions: [Int: EmbeddedCheckpointProbeResult]

    init(pending: [LibraryItemMetadata], failWritesFor: Set<Int> = [],
         embeddedVersions: [Int: EmbeddedCheckpointProbeResult] = [:]) {
        self.pending = pending
        self.failWritesFor = failWritesFor
        self.embeddedVersions = embeddedVersions
    }

    func scanPendingItems() async throws -> CheckpointBackfillScan {
        CheckpointBackfillScan(pending: pending, examinedIDs: pending.map(\.itemID))
    }

    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws {
        if failWritesFor.contains(metadata.itemID) { throw LibraryBackfillSidecarStoreError.vaultLocked }
        written.append(metadata)
    }

    func embeddedCheckpointVersionID(for metadata: LibraryItemMetadata) async -> EmbeddedCheckpointProbeResult {
        embeddedVersions[metadata.itemID] ?? .noVersion
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

    @Test func recognizesRawAndStructuredCheckpointReferences() throws {
        #expect(rawVersionData().rawCheckpointVersionID == 290640)
        let structured = GenerationData(
            type: "image",
            meta: GenerationMeta(prompt: "a portrait", negativePrompt: nil, cfgScale: nil,
                                 steps: nil, sampler: nil, seed: nil, clipSkip: nil,
                                 civitaiResources: [CivitaiResourceReference(type: "checkpoint", modelVersionId: 42)]),
            resources: nil
        )
        let roundTrip = try JSONDecoder().decode(
            GenerationData.self, from: JSONEncoder().encode(structured))
        #expect(roundTrip.rawCheckpointVersionID == 42)
        #expect(GenerationData(type: "image", meta: nil, resources: nil).rawCheckpointVersionID == nil)
    }

    @Test func resolvedCheckpointKeepsAnUnrelatedUnnamedResource() {
        let unnamed = GenerationResource(modelId: 4, modelName: nil, modelType: "Checkpoint",
                                         versionId: 999, versionName: nil, strength: nil)
        let source = GenerationData(type: "image", meta: nil, resources: [unnamed])
        let updated = source.addingResolvedCheckpoint(ponyVersion())
        #expect(updated.resources?.count == 2)
        #expect(updated.resources?.first?.versionId == 999)
        #expect(PersistedLibraryItem.checkpointGrouping(for: updated).name == "Pony Diffusion V6 XL")
    }

    @Test func oldSidecarKeepsItsOneTimeProbeThroughAlbumRewrite() throws {
        let source = makeMeta(itemID: 20, generationData: genData(checkpoint: nil))
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 6
        json.removeValue(forKey: "checkpointVersionProbePending")
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.checkpointVersionProbePending)
        #expect(PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: old))
        #expect(old.settingAlbumIDs(["A1"]).checkpointVersionProbePending)
    }

    @Test func oldV7SidecarQueuesEmbeddedProbeEvenAfterAPILookupFailed() throws {
        let source = makeMeta(itemID: 40, generationData: genData(checkpoint: nil),
                              checkpointAttemptedAt: Date())
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 7
        json.removeValue(forKey: "embeddedCheckpointProbePending")
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.embeddedCheckpointProbePending)
        #expect(PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: old))
        #expect(old.settingAlbumIDs(["A1"]).embeddedCheckpointProbePending)
    }

    @Test func v8SidecarRequeuesEvenWhenItsOldEmbeddedProbeSaidDone() throws {
        let source = makeMeta(itemID: 49, generationData: genData(checkpoint: nil),
                              checkpointAttemptedAt: Date())
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 8
        json["embeddedCheckpointProbePending"] = false
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.embeddedCheckpointProbePending)
        #expect(PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: old))
    }

    @Test func fileStoreFindsCheckpointInTheDisplayedEmbeddedRawParameters() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = """
        a portrait
        Negative prompt: blurry
        Steps: 30, Sampler: Euler a, CFG scale: 4, Seed: 123456, Civitai resources: [{"type":"checkpoint","modelVersionId":290640},{"type":"lora","modelVersionId":215378}]
        """
        let png = EmbeddedMetadataReaderTests.makePNG(textChunks: [("parameters", raw)])
        try png.write(to: directory.appendingPathComponent("41.jpeg"))
        let store = FileLibraryBackfillSidecarStore(
            itemsDirectory: directory, resolveVaultContext: { (.notConfigured, nil) })
        #expect(await store.embeddedCheckpointVersionID(for: makeMeta(itemID: 41)) == .version(290640))
    }

    @Test func embeddedNamedCheckpointSurvivesBracketedLoraNames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = """
        a portrait
        Negative prompt: blurry
        Steps: 24, Sampler: Euler a, Seed: 123456, Civitai resources: [{"type":"checkpoint","modelVersionId":290640,"modelName":"Pony Diffusion V6 XL","modelVersionName":"V6 (start with this one)"},{"type":"lora","modelVersionId":354128,"modelName":"[GP] somethingweird style [Pony XL]"},{"type":"lora","modelName":"Vixon\\u0027s Pony Styles"}]
        """
        #expect(GenerationData.checkpointID(in: raw) == 290640)
        let png = EmbeddedMetadataReaderTests.makePNG(textChunks: [("parameters", raw)])
        try png.write(to: directory.appendingPathComponent("46.jpeg"))
        let store = FileLibraryBackfillSidecarStore(
            itemsDirectory: directory, resolveVaultContext: { (.notConfigured, nil) })
        #expect(await store.embeddedCheckpointVersionID(for: makeMeta(itemID: 46))
                == .named(name: "Pony Diffusion V6 XL", versionID: 290640,
                          versionName: "V6 (start with this one)"))
    }

    @Test func unlockedVaultReadsEmbeddedCheckpointFromEncryptedMedia() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let raw = "Steps: 30, Civitai resources: [{\"type\":\"checkpoint\",\"modelVersionId\":290640}]"
        let png = EmbeddedMetadataReaderTests.makePNG(textChunks: [("parameters", raw)])
        try LibraryFileStore(itemsDirectory: directory, crypto: crypto)
            .writeMedia(png, itemID: 44, plaintextExtension: "jpeg")
        let store = FileLibraryBackfillSidecarStore(
            itemsDirectory: directory, resolveVaultContext: { (.unlocked, crypto) })
        #expect(await store.embeddedCheckpointVersionID(for: makeMeta(itemID: 44)) == .version(290640))
    }

    @Test func fileScanSelectsOldUngroupedSidecarButSkipsNewOne() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = makeMeta(itemID: 30, generationData: genData(checkpoint: nil))
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(old)) as! [String: Any]
        json["schemaVersion"] = 6
        json.removeValue(forKey: "checkpointVersionProbePending")
        try JSONSerialization.data(withJSONObject: json)
            .write(to: directory.appendingPathComponent("30.json"))
        let new = makeMeta(itemID: 31, generationData: genData(checkpoint: nil))
        try LibraryItemMetadata.encoder().encode(new)
            .write(to: directory.appendingPathComponent("31.json"))

        let store = FileLibraryBackfillSidecarStore(
            itemsDirectory: directory,
            resolveVaultContext: { (.notConfigured, nil) })
        let scan = try await store.scanPendingItems()
        #expect(Set(scan.examinedIDs) == [30, 31])
        #expect(scan.pending.map(\.itemID) == [30])
    }

    @Test func rawCheckpointIDIsEligibleButNamedCheckpointIsNot() {
        #expect(PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(
            for: makeMeta(itemID: 21, generationData: rawVersionData())))
        #expect(!PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(
            for: makeMeta(itemID: 22, generationData: genData(checkpoint: "Pony"))))
        #expect(!PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(
            for: makeMeta(itemID: 23, generationData: rawVersionData(),
                          checkpointAttemptedAt: Date())))
        #expect(PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(
            for: makeMeta(itemID: 36, attemptedAt: Date(), checkpointProbePending: true)))
    }

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

    @Test @MainActor func indexCountTriggersAutomaticRawVersionBackfill() throws {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(PersistedLibraryItem(
            metadata: makeMeta(itemID: 34, generationData: rawVersionData()),
            downloadStatus: .downloaded))
        try container.mainContext.save()

        let sort = LibrarySortService(modelContext: container.mainContext)
        #expect(sort.countItemsNeedingCheckpointBackfill() == 1)
    }

    @Test @MainActor func auditRequeuesOldIndexRowsThatNeedEmbeddedMedia() async throws {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let row = PersistedLibraryItem(
            metadata: makeMeta(itemID: 43, generationData: genData(checkpoint: nil),
                               checkpointAttemptedAt: Date()),
            downloadStatus: .downloaded)
        container.mainContext.insert(row)
        try container.mainContext.save()
        #expect(!row.needsCheckpointVersionBackfill)

        let index = LibraryIndexService(modelContainer: container)
        await index.markCheckpointVersionAuditComplete(examinedIDs: [43], pendingIDs: [43])
        let verifyContext = ModelContext(container)
        let saved = try verifyContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        #expect(saved.first?.needsCheckpointVersionBackfill == true)
    }
}

// MARK: - Run loop

@Suite @MainActor struct CheckpointBackfillRunTests {

    private func service(
        pending: [LibraryItemMetadata],
        outcomes: [Int: StubFetcher.Outcome],
        versions: [Int: StubFetcher.VersionOutcome] = [:],
        raw: [Int: StubFetcher.RawOutcome] = [:],
        failWritesFor: Set<Int> = [],
        embeddedVersions: [Int: EmbeddedCheckpointProbeResult] = [:]
    ) throws -> (LibraryCheckpointBackfillService, StubStore, StubFetcher) {
        let store = StubStore(pending: pending, failWritesFor: failWritesFor,
                              embeddedVersions: embeddedVersions)
        let fetcher = StubFetcher(outcomes, versions: versions, raw: raw)
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

    @Test func embeddedIDRecoversAnItemPreviouslyMarkedUnavailableByCivitai() async throws {
        let source = makeMeta(itemID: 42, generationData: genData(checkpoint: nil),
                              checkpointAttemptedAt: Date())
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 7
        json.removeValue(forKey: "embeddedCheckpointProbePending")
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        let (service, store, _) = try service(
            pending: [old], outcomes: [:], versions: [290640: .resource(ponyVersion())],
            embeddedVersions: [42: .version(290640)])
        await service.runOnce()
        let updated = await store.writtenMetadata().first
        #expect(updated.map { PersistedLibraryItem.checkpointGrouping(for: $0).name } == "Pony Diffusion V6 XL")
        #expect(updated?.embeddedCheckpointProbePending == false)
        #expect(updated?.checkpointVersionLookupAttemptedAt == nil)
        #expect(service.summary == CheckpointBackfillSummary(
            checked: 1, grouped: 1, unresolved: 0, retryLater: 0))
    }

    @Test func embeddedCheckpointNameGroupsWithoutASecondNetworkLookup() async throws {
        let source = makeMeta(itemID: 47, generationData: genData(checkpoint: nil),
                              checkpointAttemptedAt: Date())
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 7
        json.removeValue(forKey: "embeddedCheckpointProbePending")
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        let (service, store, fetcher) = try service(
            pending: [old], outcomes: [:],
            embeddedVersions: [47: .named(name: "Pony Diffusion V6 XL", versionID: 290640,
                                          versionName: "V6 (start with this one)")])
        await service.runOnce()
        let updated = await store.writtenMetadata().first
        #expect(updated.map { PersistedLibraryItem.checkpointGrouping(for: $0).name } == "Pony Diffusion V6 XL")
        #expect(updated?.generationData?.resources?.first(where: { $0.modelType == "Checkpoint" })?.versionId == 290640)
        #expect(await fetcher.requestedVersionIDs().isEmpty)
    }

    @Test func structuredRawCheckpointNameAlsoAvoidsVersionLookup() async throws {
        let generation = GenerationData(
            type: "image",
            meta: GenerationMeta(
                prompt: "a portrait", negativePrompt: nil, cfgScale: nil,
                steps: nil, sampler: nil, seed: nil, clipSkip: nil,
                civitaiResources: [CivitaiResourceReference(
                    type: "checkpoint", modelVersionId: 290640,
                    modelName: "Pony Diffusion V6 XL", modelVersionName: "V6")]),
            resources: nil)
        let (service, store, fetcher) = try service(
            pending: [makeMeta(itemID: 48, generationData: generation)], outcomes: [:])
        await service.runOnce()
        let updated = await store.writtenMetadata().first
        #expect(updated.map { PersistedLibraryItem.checkpointGrouping(for: $0).name } == "Pony Diffusion V6 XL")
        #expect(await fetcher.requestedVersionIDs().isEmpty)
    }

    @Test func encryptedV8ItemWithNamedEmbeddedCheckpointMovesOutOfOther() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let files = LibraryFileStore(itemsDirectory: directory, crypto: crypto)
        let raw = """
        a portrait
        Negative prompt: blurry
        Steps: 24, Civitai resources: [{"type":"checkpoint","modelVersionId":290640,"modelName":"Pony Diffusion V6 XL","modelVersionName":"V6"},{"type":"lora","modelName":"[GP] style"}]
        """
        try files.writeMedia(
            EmbeddedMetadataReaderTests.makePNG(textChunks: [("parameters", raw)]),
            itemID: 50, plaintextExtension: "jpeg")
        let source = makeMeta(itemID: 50, generationData: genData(checkpoint: nil),
                              checkpointAttemptedAt: Date())
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 8
        json["embeddedCheckpointProbePending"] = false
        try files.writeMetadata(try JSONSerialization.data(withJSONObject: json), itemID: 50)
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: files.readMetadata(itemID: 50)!)

        let index = try makeIndexService()
        await index.ingest(metadata: old, downloadStatus: .downloaded)
        let fetcher = StubFetcher([:])
        let service = LibraryCheckpointBackfillService(
            indexService: index,
            sidecarStore: FileLibraryBackfillSidecarStore(
                itemsDirectory: directory, resolveVaultContext: { (.unlocked, crypto) }),
            fetcher: fetcher)
        await service.runOnce()

        let saved = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: files.readMetadata(itemID: 50)!)
        #expect(saved.schemaVersion == LibraryItemMetadata.currentSchemaVersion)
        #expect(PersistedLibraryItem.checkpointGrouping(for: saved).name == "Pony Diffusion V6 XL")
        #expect(await index.checkpointIndexSnapshot().names[50] == "Pony Diffusion V6 XL")
        #expect(await fetcher.requestedVersionIDs().isEmpty)
    }

    @Test func absentEmbeddedIDIsUnresolvedButUnavailableMediaRetries() async throws {
        let source = makeMeta(itemID: 45, generationData: genData(checkpoint: nil),
                              checkpointAttemptedAt: Date())
        var json = try JSONSerialization.jsonObject(with: LibraryItemMetadata.encoder().encode(source)) as! [String: Any]
        json["schemaVersion"] = 7
        json.removeValue(forKey: "embeddedCheckpointProbePending")
        let old = try LibraryItemMetadata.decoder().decode(
            LibraryItemMetadata.self, from: JSONSerialization.data(withJSONObject: json))

        let (unresolved, store, _) = try service(pending: [old], outcomes: [:])
        await unresolved.runOnce()
        let updated = await store.writtenMetadata().first
        #expect(updated?.embeddedCheckpointProbePending == false)
        #expect(unresolved.summary == CheckpointBackfillSummary(
            checked: 1, grouped: 0, unresolved: 1, retryLater: 0))

        let (retry, unavailableStore, _) = try service(
            pending: [old], outcomes: [:], embeddedVersions: [45: .unavailable])
        await retry.runOnce()
        #expect(await unavailableStore.writtenMetadata().isEmpty)
        #expect(retry.summary == CheckpointBackfillSummary(
            checked: 1, grouped: 0, unresolved: 0, retryLater: 1))
    }

    @Test func stampsTheMarkerWhenCivitaiConfirmsThereIsNothing() async throws {
        let (service, store, _) = try service(
            pending: [makeMeta(itemID: 2)], outcomes: [2: .noData], raw: [2: .missing])
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
        #expect(service.summary == CheckpointBackfillSummary(
            checked: 1, grouped: 0, unresolved: 0, retryLater: 1))
    }

    @Test func oneBadItemDoesNotStopTheQueue() async throws {
        let (service, store, fetcher) = try service(
            pending: [makeMeta(itemID: 1), makeMeta(itemID: 2), makeMeta(itemID: 3)],
            outcomes: [1: .transient,
                       2: .success(genData(checkpoint: "Hassaku")),
                       3: .noData],
            raw: [3: .missing])
        await service.runOnce()

        #expect(await fetcher.requestedIDs() == [1, 2, 3])
        #expect(service.completedItemCount == 3)
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

    @Test func resolvesRawVersionWithoutRefetchingImageAndPreservesAlbums() async throws {
        let source = makeMeta(itemID: 24, generationData: rawVersionData(), albumIDs: ["A1"])
        let (service, store, fetcher) = try service(
            pending: [source], outcomes: [:], versions: [290640: .resource(ponyVersion())])
        await service.runOnce()

        let written = await store.writtenMetadata().first
        #expect(await fetcher.requestedIDs().isEmpty)
        #expect(await fetcher.requestedVersionIDs() == [290640])
        #expect(written?.albumIDs == ["A1"])
        #expect(written?.generationData?.resources?.first(where: { $0.modelType == "Checkpoint" })?.versionId == 290640)
        #expect(written.map { PersistedLibraryItem.checkpointGrouping(for: $0).name } == "Pony Diffusion V6 XL")
        #expect(written?.checkpointVersionLookupAttemptedAt == nil)
    }

    @Test func publicRawMetadataRecoversAnImageWhoseGenerationResponseIsNull() async throws {
        let (service, store, fetcher) = try service(
            pending: [makeMeta(itemID: 29)], outcomes: [29: .noData],
            versions: [290640: .resource(ponyVersion())], raw: [29: .version(290640)])
        await service.runOnce()

        let updated = await store.writtenMetadata().first
        #expect(await fetcher.requestedIDs() == [29])
        #expect(await fetcher.requestedRawImageIDs() == [29])
        #expect(updated?.generationDataBackfillAttemptedAt == nil)
        #expect(updated.map { PersistedLibraryItem.checkpointGrouping(for: $0).name } == "Pony Diffusion V6 XL")
    }

    @Test func confirmedNullGenerationStillGetsOnePublicMetadataProbe() async throws {
        let source = makeMeta(itemID: 35, attemptedAt: Date(), checkpointProbePending: true)
        let (service, store, fetcher) = try service(
            pending: [source], outcomes: [:], versions: [290640: .resource(ponyVersion())],
            raw: [35: .version(290640)])
        await service.runOnce()

        #expect(await fetcher.requestedIDs().isEmpty)
        #expect(await fetcher.requestedRawImageIDs() == [35])
        let updated = await store.writtenMetadata().first
        #expect(updated?.generationDataBackfillAttemptedAt == nil)
        #expect(updated.map { PersistedLibraryItem.checkpointGrouping(for: $0).name } == "Pony Diffusion V6 XL")
    }

    @Test func missingVersionIsStampedButTimeoutRemainsRetryable() async throws {
        let missing = try service(
            pending: [makeMeta(itemID: 25, generationData: rawVersionData())],
            outcomes: [:], versions: [290640: .notFound])
        await missing.0.runOnce()
        let failedLookup = await missing.1.writtenMetadata().first
        #expect(failedLookup?.checkpointVersionLookupAttemptedAt != nil)
        #expect(failedLookup.map { PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: $0) } == false)

        let transient = try service(
            pending: [makeMeta(itemID: 26, generationData: rawVersionData())],
            outcomes: [:], versions: [290640: .transient])
        await transient.0.runOnce()
        #expect(await transient.1.writtenMetadata().isEmpty)
    }

    @Test func sharedCheckpointVersionIsLookedUpOncePerRun() async throws {
        let (service, store, fetcher) = try service(
            pending: [
                makeMeta(itemID: 32, generationData: rawVersionData()),
                makeMeta(itemID: 33, generationData: rawVersionData())
            ], outcomes: [:], versions: [290640: .resource(ponyVersion())])
        await service.runOnce()

        #expect(await fetcher.requestedVersionIDs() == [290640])
        #expect(await store.writtenMetadata().count == 2)
    }

    @Test func oldUngroupedSidecarGetsOneGenerationProbeForDiscardedRawFields() async throws {
        let original = makeMeta(itemID: 27, generationData: genData(checkpoint: nil), checkpointProbePending: true)
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let row = PersistedLibraryItem(metadata: original, downloadStatus: .downloaded)
        row.needsCheckpointVersionBackfill = true // pre-upgrade index row
        container.mainContext.insert(row)
        try container.mainContext.save()

        let store = StubStore(pending: [original])
        let fetcher = StubFetcher([:], versions: [290640: .resource(ponyVersion())],
                                  raw: [27: .version(290640)])
        let index = LibraryIndexService(modelContainer: container)
        let service = LibraryCheckpointBackfillService(indexService: index, sidecarStore: store, fetcher: fetcher)
        await service.runOnce()

        #expect(await fetcher.requestedIDs().isEmpty)
        #expect(await fetcher.requestedRawImageIDs() == [27])
        #expect(await fetcher.requestedVersionIDs() == [290640])
        #expect(await store.writtenMetadata().first?.albumIDs == [])
        #expect(await index.checkpointIndexSnapshot().names[27] == "Pony Diffusion V6 XL")
    }

    @Test func probeWithNoRawCheckpointIsRecordedOnce() async throws {
        let original = makeMeta(itemID: 28, generationData: genData(checkpoint: nil), checkpointProbePending: true)
        let (service, store, fetcher) = try service(
            pending: [original], outcomes: [:], raw: [28: .missing])
        await service.runOnce()

        let updated = await store.writtenMetadata().first
        #expect(await fetcher.requestedRawImageIDs() == [28])
        #expect(updated?.checkpointVersionLookupAttemptedAt != nil)
        #expect(updated?.checkpointVersionProbePending == false)
        #expect(updated.map { PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: $0) } == false)
    }

    @Test func isIdempotentWhenNothingIsPending() async throws {
        let (service, store, fetcher) = try service(pending: [], outcomes: [:])
        await service.runOnce()
        #expect(await fetcher.requestedIDs().isEmpty)
        #expect(await store.writtenMetadata().isEmpty)
        #expect(service.remaining == 0)
        #expect(service.completedItemCount == 0)
    }

    @Test func reportsRemainingForTheProgressBanner() async throws {
        let (service, _, _) = try service(
            pending: [makeMeta(itemID: 1), makeMeta(itemID: 2)],
            outcomes: [1: .transient, 2: .transient])
        await service.runOnce()
        #expect(service.remaining == 0)
        #expect(!service.isRunning)
        #expect(service.completedItemCount == 2)
    }
}
