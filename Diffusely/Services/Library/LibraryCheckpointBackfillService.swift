import Foundation

/// Sidecar-store seam for `LibraryCheckpointBackfillService`. Deliberately a
/// separate protocol from `LibraryBackfillSidecarStore` (dates) because the
/// pending query differs; `FileLibraryBackfillSidecarStore` conforms to both
/// so there is still exactly one vault-aware container walk implementation.
protocol LibraryCheckpointBackfillSidecarStore: Sendable {
    /// Pending items plus the decoded sidecars examined during the walk. The
    /// latter lets the index clear its one-time migration flag without
    /// treating unreadable iCloud placeholders as audited.
    func scanPendingItems() async throws -> CheckpointBackfillScan
    /// Atomically rewrites the sidecar for an already-committed item.
    func rewriteMetadata(_ metadata: LibraryItemMetadata) async throws
    /// Reads the same embedded generation text shown by Library detail.
    func embeddedCheckpointVersionID(for metadata: LibraryItemMetadata) async -> EmbeddedCheckpointProbeResult
}

enum EmbeddedCheckpointProbeResult: Equatable, Sendable {
    case named(name: String, versionID: Int?, versionName: String?)
    case version(Int)
    case noVersion
    case unavailable
}

struct CheckpointBackfillScan {
    let pending: [LibraryItemMetadata]
    let examinedIDs: [Int]
}

struct CheckpointBackfillSummary: Codable, Equatable {
    let checked: Int
    let grouped: Int
    let unresolved: Int
    let retryLater: Int
}

struct CheckpointBackfillReport: Codable, Equatable {
    let completedAt: Date
    let summary: CheckpointBackfillSummary
}

extension FileLibraryBackfillSidecarStore: LibraryCheckpointBackfillSidecarStore {
    func embeddedCheckpointVersionID(for metadata: LibraryItemMetadata) async -> EmbeddedCheckpointProbeResult {
        guard metadata.mediaType == .image else { return .noVersion }
        let vault = await resolveVaultContext()
        guard vault.state != .locked else { return .unavailable }
        let store = LibraryFileStore(itemsDirectory: itemsDirectory, crypto: vault.crypto)
        let ext = (metadata.mediaFileName as NSString).pathExtension
        guard let data = await store.readMediaAsync(itemID: metadata.itemID, plaintextExtension: ext)
        else { return .unavailable }
        return await Task.detached(priority: .utility) {
            guard let raw = EmbeddedMetadataReader.read(data: data)?.raw else { return .noVersion }
            let references = GenerationData.checkpointReferences(in: raw)
            if let named = references.compactMap(\.namedCheckpointResource).first,
               let name = named.modelName {
                return .named(name: name, versionID: named.versionId,
                              versionName: named.versionName)
            }
            guard let id = references.first(where: { ($0.modelVersionId ?? 0) > 0 })?.modelVersionId
            else { return .noVersion }
            return .version(id)
        }.value
    }

    /// Same vault-aware, off-actor walk as `pendingItems()`, filtered for the
    /// generation-data backfill instead of the date one. A locked vault
    /// returns empty rather than scanning: a passthrough store built over an
    /// encrypted container would find zero readable sidecars and wrongly
    /// report nothing pending.
    func scanPendingItems() async throws -> CheckpointBackfillScan {
        let directory = itemsDirectory
        let vault = await resolveVaultContext()
        guard vault.state != .locked else { return CheckpointBackfillScan(pending: [], examinedIDs: []) }
        let crypto = vault.crypto
        return await Task.detached(priority: .utility) {
            let store = LibraryFileStore(itemsDirectory: directory, crypto: crypto)
            var pending: [LibraryItemMetadata] = []
            var examinedIDs: [Int] = []
            for url in store.enumerateMetadataFiles() {
                guard
                    let id = store.itemID(forMetadataFile: url),
                    let data = store.readMetadata(itemID: id),
                    let metadata = try? LibraryItemMetadata.decoder()
                        .decode(LibraryItemMetadata.self, from: data)
                else { continue }
                examinedIDs.append(id)
                if PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: metadata)
                    || PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: metadata) {
                    pending.append(metadata)
                }
            }
            return CheckpointBackfillScan(pending: pending, examinedIDs: examinedIDs)
        }.value
    }
}

/// One-shot serial backfill for missing generation data or a raw checkpoint
/// version ID that Civitai did not include in resolved resources. For an
/// ungrouped saved image it also inspects the embedded parameters displayed
/// in Library detail, which may be the only place the version ID survives.
///
/// Scope stays narrow. Measured across a real 7,830-item library, the
/// ungrouped items split three ways:
///
/// * no generation data at all (81) — 16 of 25 sampled have a checkpoint on
///   Civitai today. `fetchGenerationData` is called with `try?` at save time,
///   so a failure there is silent and permanent. This service exists for them.
/// * generation data with no resolved checkpoint is eligible when its raw
///   parameters contain a version ID, or once when an older sidecar may have
///   discarded Civitai's raw resource list. The saved media and public image
///   endpoint can each supply a raw ID; the version endpoint supplies the
///   model name and type.
///
/// Mirrors `LibraryDateBackfillService`: `@MainActor` so SwiftUI can observe
/// `remaining` for the progress banner, with all file I/O delegated to a
/// `LibraryCheckpointBackfillSidecarStore` that keeps the heavy work off the
/// main thread. Failures are swallowed per item so one bad image doesn't stop
/// the queue.
@MainActor
final class LibraryCheckpointBackfillService: ObservableObject {

    /// Test seam so the suite needs no live `CivitaiService`.
    protocol FetchGenerationDataProvider: AnyObject {
        func fetchGenerationData(imageId: Int) async throws -> GenerationData
        func fetchRawCheckpointVersionID(imageId: Int) async throws -> Int?
        func fetchCheckpointVersion(versionId: Int) async throws -> GenerationResource?
    }

    @Published private(set) var remaining: Int = 0
    @Published private(set) var isRunning: Bool = false
    /// Set only after a full pass finishes. A failed scan or cancellation does
    /// not claim that the Library's model metadata was checked.
    private(set) var completedItemCount: Int?
    private(set) var summary: CheckpointBackfillSummary?

    private let indexService: LibraryIndexService
    private let sidecarStore: LibraryCheckpointBackfillSidecarStore
    private let fetcher: FetchGenerationDataProvider
    private var resolvedVersionCache: [Int: GenerationResource] = [:]
    private var unavailableVersionIDs: Set<Int> = []

    init(
        indexService: LibraryIndexService,
        sidecarStore: LibraryCheckpointBackfillSidecarStore,
        fetcher: FetchGenerationDataProvider
    ) {
        self.indexService = indexService
        self.sidecarStore = sidecarStore
        self.fetcher = fetcher
    }

    /// Convenience initializer that builds the default file-backed store,
    /// matching `LibraryDateBackfillService`'s.
    convenience init(
        indexService: LibraryIndexService,
        itemsDirectory: URL,
        fetcher: FetchGenerationDataProvider
    ) {
        self.init(
            indexService: indexService,
            sidecarStore: FileLibraryBackfillSidecarStore(itemsDirectory: itemsDirectory),
            fetcher: fetcher
        )
    }

    /// Walk the container once and re-fetch generation data for every eligible
    /// item. Idempotent: with everything filled or attempted, this is a no-op.
    func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        completedItemCount = nil
        summary = nil
        defer { isRunning = false }

        guard let scan = try? await sidecarStore.scanPendingItems() else { return }
        let pending = scan.pending
        await indexService.markCheckpointVersionAuditComplete(
            examinedIDs: scan.examinedIDs,
            pendingIDs: Set(pending.map(\.itemID))
        )
        remaining = pending.count
        var grouped = 0
        var unresolved = 0
        var retryLater = 0

        for metadata in pending {
            if Task.isCancelled { return }
            enum Result { case grouped, unresolved, retryLater }
            var result: Result = .retryLater
            defer {
                remaining = max(0, remaining - 1)
                switch result {
                case .grouped: grouped += 1
                case .unresolved: unresolved += 1
                case .retryLater: retryLater += 1
                }
            }

            var generationData = metadata.generationData
            var generationAttemptedAt = metadata.generationDataBackfillAttemptedAt
            var checkpointAttemptedAt = metadata.checkpointVersionLookupAttemptedAt
            var probePending = metadata.checkpointVersionProbePending
            var embeddedProbePending = metadata.embeddedCheckpointProbePending
            var shouldWrite = false
            let wasMissingGenerationData = generationData == nil

            if generationData == nil && generationAttemptedAt == nil {
                do {
                    generationData = try await fetcher.fetchGenerationData(imageId: metadata.itemID)
                    shouldWrite = true
                } catch is DecodingError {
                    // A confirmed null response is distinct from a timeout.
                    generationAttemptedAt = Date()
                    probePending = false
                    shouldWrite = true
                } catch {
                    // The local image can still identify its checkpoint when
                    // Civitai's generation endpoint is unavailable.
                }
            }

            if let current = generationData,
               PersistedLibraryItem.checkpointGrouping(for: current).name == nil,
               let named = current.namedRawCheckpointResource {
                generationData = current.addingResolvedCheckpoint(named)
                checkpointAttemptedAt = nil
                probePending = false
                embeddedProbePending = false
                shouldWrite = true
            }

            if embeddedProbePending,
               metadata.mediaType == .image,
               PersistedLibraryItem.checkpointGrouping(for: generationData).name == nil {
                // Respect the index's local-availability state: probing an
                // evicted iCloud original would download the whole image just
                // to inspect its metadata. Keep the marker for a later run.
                let mediaStatus = await indexService.currentDownloadStatus(itemID: metadata.itemID)
                let embeddedResult: EmbeddedCheckpointProbeResult =
                    mediaStatus == nil || mediaStatus == .downloaded
                    ? await sidecarStore.embeddedCheckpointVersionID(for: metadata)
                    : .unavailable
                switch embeddedResult {
                case .named(let name, let versionID, let versionName):
                    let basis = generationData ?? GenerationData(type: "image", meta: nil, resources: nil)
                    let checkpoint = GenerationResource(
                        modelId: nil, modelName: name, modelType: "Checkpoint",
                        versionId: versionID, versionName: versionName, strength: nil)
                    generationData = basis.addingResolvedCheckpoint(checkpoint)
                    checkpointAttemptedAt = nil
                    probePending = false
                    embeddedProbePending = false
                    shouldWrite = true
                case .version(let id):
                    let basis = generationData ?? GenerationData(type: "image", meta: nil, resources: nil)
                    if basis.rawCheckpointVersionID != id {
                        generationData = basis.addingRawCheckpointVersionID(id)
                        checkpointAttemptedAt = nil
                    }
                    embeddedProbePending = false
                    shouldWrite = true
                case .noVersion:
                    embeddedProbePending = false
                    shouldWrite = true
                case .unavailable:
                    break // Keep it eligible when an iCloud media file arrives.
                }
            }

            if (probePending || wasMissingGenerationData),
               checkpointAttemptedAt == nil,
               generationData?.rawCheckpointVersionID == nil,
               PersistedLibraryItem.checkpointGrouping(for: generationData).name == nil {
                let basis = generationData ?? GenerationData(type: "image", meta: nil, resources: nil)
                do {
                    if let rawID = try await fetcher.fetchRawCheckpointVersionID(imageId: metadata.itemID) {
                        generationData = basis.addingRawCheckpointVersionID(rawID)
                        generationAttemptedAt = nil
                    } else {
                        checkpointAttemptedAt = Date()
                    }
                    probePending = false
                    shouldWrite = true
                } catch let error as HTTPStatusError where error.statusCode == 404 {
                    checkpointAttemptedAt = Date()
                    probePending = false
                    shouldWrite = true
                } catch {
                    // Keep a newly fetched generation record and retry the
                    // raw metadata probe on the next Library opening.
                    if !shouldWrite { continue }
                    probePending = true
                }
            }

            if let rawVersionID = generationData?.rawCheckpointVersionID,
               let currentGeneration = generationData,
               PersistedLibraryItem.checkpointGrouping(for: currentGeneration).name == nil,
               checkpointAttemptedAt == nil {
                do {
                    if let checkpoint = try await resolveCheckpointVersion(rawVersionID) {
                        generationData = currentGeneration.addingResolvedCheckpoint(checkpoint)
                    } else {
                        checkpointAttemptedAt = Date()
                    }
                    probePending = false
                    shouldWrite = true
                } catch let error as HTTPStatusError where error.statusCode == 404 {
                    checkpointAttemptedAt = Date()
                    probePending = false
                    shouldWrite = true
                } catch {
                    // Preserve newly fetched generation data so the next
                    // session can retry only the version lookup.
                }
            }

            if PersistedLibraryItem.checkpointGrouping(for: generationData).name != nil {
                probePending = false
                embeddedProbePending = false
            }

            guard shouldWrite else { continue }
            let updated = Self.merged(
                base: metadata, generationData: generationData,
                generationAttemptedAt: generationAttemptedAt,
                checkpointAttemptedAt: checkpointAttemptedAt,
                probePending: probePending,
                embeddedProbePending: embeddedProbePending
            )

            do {
                try await sidecarStore.rewriteMetadata(updated)
            } catch {
                continue
            }
            let status = await indexService.currentDownloadStatus(itemID: metadata.itemID) ?? .downloaded
            await indexService.ingest(metadata: updated, downloadStatus: status)
            if PersistedLibraryItem.checkpointGrouping(for: updated).name != nil {
                result = .grouped
            } else if !PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: updated)
                        && !PersistedLibraryItem.computeNeedsCheckpointVersionBackfill(for: updated) {
                result = .unresolved
            }
        }
        completedItemCount = pending.count
        summary = CheckpointBackfillSummary(
            checked: pending.count, grouped: grouped,
            unresolved: unresolved, retryLater: retryLater)
    }

    private func resolveCheckpointVersion(_ id: Int) async throws -> GenerationResource? {
        if let cached = resolvedVersionCache[id] { return cached }
        if unavailableVersionIDs.contains(id) { return nil }
        do {
            let resource = try await fetcher.fetchCheckpointVersion(versionId: id)
            if let resource { resolvedVersionCache[id] = resource }
            else { unavailableVersionIDs.insert(id) }
            return resource
        } catch let error as HTTPStatusError where error.statusCode == 404 {
            unavailableVersionIDs.insert(id)
            throw error
        }
    }

    /// Build a current-schema sidecar from an existing one, swapping in the
    /// fetched generation data and the attempt marker. Everything else —
    /// `albumIDs` especially, whose silent default to [] once wiped album
    /// membership on every date-backfill rewrite — is preserved verbatim.
    private static func merged(
        base: LibraryItemMetadata,
        generationData: GenerationData?,
        generationAttemptedAt: Date?,
        checkpointAttemptedAt: Date?,
        probePending: Bool,
        embeddedProbePending: Bool
    ) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: base.itemID,
            sourcePostID: base.sourcePostID,
            sourcePostTitle: base.sourcePostTitle,
            canonicalPostURL: base.canonicalPostURL,
            canonicalPageURL: base.canonicalPageURL,
            sourceDomain: base.sourceDomain,
            originalCDNURL: base.originalCDNURL,
            mediaType: base.mediaType,
            mediaFileName: base.mediaFileName,
            fileByteSize: base.fileByteSize,
            contentSHA256: base.contentSHA256,
            width: base.width,
            height: base.height,
            nsfwLevel: base.nsfwLevel,
            author: base.author,
            stats: base.stats,
            generationData: generationData ?? base.generationData,
            publishedAt: base.publishedAt,
            publishedAtBackfillAttemptedAt: base.publishedAtBackfillAttemptedAt,
            generationDataBackfillAttemptedAt: generationAttemptedAt,
            checkpointVersionLookupAttemptedAt: checkpointAttemptedAt,
            checkpointVersionProbePending: probePending,
            embeddedCheckpointProbePending: embeddedProbePending,
            albumIDs: base.albumIDs,
            savedAt: base.savedAt,
            savedByAppVersion: base.savedByAppVersion
        )
    }
}

/// Bridges the live `CivitaiService` to the backfill's fetch seam, mirroring
/// `CivitaiServiceFetchImageAdapter` — `@MainActor` because `CivitaiService`
/// is main-actor isolated.
@MainActor
final class CivitaiServiceGenerationDataAdapter: LibraryCheckpointBackfillService.FetchGenerationDataProvider {
    private let service = CivitaiService()

    func fetchGenerationData(imageId: Int) async throws -> GenerationData {
        try await service.fetchGenerationData(imageId: imageId)
    }

    func fetchCheckpointVersion(versionId: Int) async throws -> GenerationResource? {
        try await service.fetchCheckpointVersion(versionId: versionId)
    }

    func fetchRawCheckpointVersionID(imageId: Int) async throws -> Int? {
        try await service.fetchRawCheckpointVersionID(imageId: imageId)
    }
}
