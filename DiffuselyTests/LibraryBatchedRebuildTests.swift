import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct LibraryBatchedRebuildTests {
    private func metadata(_ id: Int) -> LibraryItemMetadata {
        LibraryItemMetadata(schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: id,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(id)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil), stats: nil,
            generationData: nil, publishedAt: nil, albumIDs: [], savedAt: Date(), savedByAppVersion: "t")
    }
    private func fixture() throws -> (URL, LibraryIndexService) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer(for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return (directory, LibraryIndexService(modelContainer: container))
    }
    private func write(_ id: Int, to directory: URL) throws {
        try LibraryItemMetadata.encoder().encode(metadata(id)).write(to: directory.appendingPathComponent("\(id).json"))
    }

    @Test func interruptedBatchesKeepRowsAndResumeOnlyCommittedFingerprints() async throws {
        let (directory, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("checkpoint/state")
        for id in 1...4 { try write(id, to: directory) }
        await service.ingest(metadata: metadata(999), downloadStatus: .downloaded)
        let epoch = await service.currentMutationEpoch()
        let store = LibraryFileStore(itemsDirectory: directory, crypto: nil)
        let interrupted = await Task {
            await service.reconcileInBatches(store: store, knownItems: [], knownAlbums: [], fingerprints: [:],
                isPlaceholder: nil, epoch: epoch, startedAtGeneration: 0, generationProbe: { 0 },
                rebuilding: true, progress: { _ in
                    // The absent row survives until the complete walk, while a
                    // new row has already been published before scanning ends.
                    #expect(await service.itemCount() == 2)
                    withUnsafeCurrentTask { $0?.cancel() }
                }, checkpointURL: checkpoint, batchSize: 1)
        }.value
        #expect(interrupted.pendingItems == nil)
        let root = directory.standardizedFileURL.path + "#plain"
        let saved = LibraryScanCheckpoint.load(at: checkpoint, root: root)
        #expect(saved.completed.count == 1)
        let committedID = try #require(saved.completed.values.first?.itemID)
        #expect(await service.indexedFingerprints().values.contains { $0.itemID == committedID })
        // An ordinary launch reconcile detects and resumes the interrupted
        // explicit rebuild, rather than trusting untouched older fingerprints.
        let complete = await service.reconcile(itemsDirectory: directory,
            startedAtGeneration: 0, generationProbe: { 0 }, checkpointURL: checkpoint)
        #expect(complete.pendingItems == 0)
        #expect(complete.sidecarsRead == 3, "the committed unchanged sidecar must not be read again")
        #expect(await service.itemCount() == 4)
        #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
    }

    @Test func journalDeltaUpdatesAndDeletesOnlyNamedRows() async throws {
        let (directory, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LibraryChangeJournal(root: directory, writerID: UUID().uuidString)
        try journal.prepare()
        let baseline = try journal.snapshot()
        for id in [1, 2, 999] {
            try write(id, to: directory)
            await service.ingest(metadata: metadata(id), downloadStatus: .downloaded)
        }
        await service.installJournalBaselineForTest(baseline, key: "test")
        try journal.withMutation(names: ["1.json", "2.json", "3.json"]) {
            try write(1, to: directory)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("2.json"))
            try write(3, to: directory)
        }
        let outcome = await service.reconcileJournalChanges(journal: journal, snapshot: try journal.snapshot(),
            key: "test", store: LibraryFileStore(itemsDirectory: directory, crypto: nil),
            epoch: await service.currentMutationEpoch(), startedAtGeneration: 0, generationProbe: { 0 })
        #expect(outcome != nil)
        #expect(outcome?.sidecarsRead == 2)
        #expect(await service.itemCount() == 3)
        #expect(await service.currentDownloadStatus(itemID: 999) == .downloaded)
        #expect(await service.currentDownloadStatus(itemID: 2) == nil)
        #expect(await service.currentDownloadStatus(itemID: 3) != nil)
        // After the audit interval even a clean journal must request a full
        // scan, to catch changes made outside the app.
        await service.installJournalBaselineForTest(try journal.snapshot(), key: "test",
            date: Date().addingTimeInterval(-LibraryIndexService.journalAuditInterval - 1))
        let expired = await service.reconcileJournalChanges(journal: journal, snapshot: try journal.snapshot(),
            key: "test", store: LibraryFileStore(itemsDirectory: directory, crypto: nil),
            epoch: await service.currentMutationEpoch(), startedAtGeneration: 0, generationProbe: { 0 })
        #expect(expired == nil)
    }

    actor Generation {
        var value = 0
        func change() { value += 1 }
    }

    @Test func rootChangeAfterBatchCannotPruneOrApplyAnotherBatch() async throws {
        let (directory, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in 1...3 { try write(id, to: directory) }
        await service.ingest(metadata: metadata(999), downloadStatus: .downloaded)
        let generation = Generation()
        let outcome = await service.reconcileInBatches(
            store: LibraryFileStore(itemsDirectory: directory, crypto: nil), knownItems: [], knownAlbums: [],
            fingerprints: [:], isPlaceholder: nil, epoch: await service.currentMutationEpoch(),
            startedAtGeneration: 0, generationProbe: { await generation.value }, rebuilding: false,
            progress: { _ in await generation.change() }, checkpointURL: nil, batchSize: 1)
        #expect(outcome.pendingItems == nil)
        #expect(await service.itemCount() == 2)
    }

    @Test func changedJournalAtEndDefersDeletion() async throws {
        let (directory, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(1, to: directory)
        await service.ingest(metadata: metadata(999), downloadStatus: .downloaded)
        let outcome = await service.reconcileInBatches(
            store: LibraryFileStore(itemsDirectory: directory, crypto: nil), knownItems: [], knownAlbums: [],
            fingerprints: [:], isPlaceholder: nil, epoch: await service.currentMutationEpoch(),
            startedAtGeneration: 0, generationProbe: { 0 }, rebuilding: false,
            progress: nil, checkpointURL: nil, batchSize: 1, finalizeCheck: { false })
        #expect(outcome.pendingItems == nil)
        #expect(await service.itemCount() == 2)
    }

    @Test func unreadableDirectoryNeverPrunes() async throws {
        let (directory, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await service.ingest(metadata: metadata(999), downloadStatus: .downloaded)
        let outcome = await service.reconcileInBatches(
            store: LibraryFileStore(itemsDirectory: directory.appendingPathComponent("missing"), crypto: nil),
            knownItems: [], knownAlbums: [], fingerprints: [:], isPlaceholder: nil,
            epoch: await service.currentMutationEpoch(), startedAtGeneration: 0, generationProbe: { 0 },
            rebuilding: false, progress: nil, checkpointURL: nil, batchSize: 1)
        #expect(outcome.pendingItems == nil)
        #expect(await service.itemCount() == 1)
    }
}

extension LibraryIndexService {
    func installJournalBaselineForTest(_ snapshot: LibraryChangeJournal.Snapshot, key: String, date: Date = Date()) {
        journalBaselines[key] = JournalBaseline(snapshot: snapshot, auditedAt: date)
    }
}
