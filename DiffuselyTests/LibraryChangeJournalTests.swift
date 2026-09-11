import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryChangeJournalTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func independentWritersAndPendingTransactionsAreVisible() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryChangeJournal(root: root, writerID: UUID().uuidString)
        let b = LibraryChangeJournal(root: root, writerID: UUID().uuidString)
        try a.withMutation(names: []) {}
        let initial = try a.snapshot()
        try a.withMutation(names: ["1.json"]) {
            #expect(try a.snapshot().changes(since: initial) == nil)
            try b.withMutation(names: ["2.json"]) {}
        }
        #expect(try a.snapshot().changes(since: initial) == ["1.json", "2.json"])
        #expect(try a.snapshot().writers.count == 2)
    }

    @Test func customStoreAndLegacyAdaptersJournalWritesAndDeletes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = UUID().uuidString
        let journal = LibraryChangeJournal(root: root, writerID: writer)
        try journal.prepare()
        let initial = try journal.snapshot()
        let store = LibraryFileStore(itemsDirectory: root, crypto: nil,
            createsContainerDirectory: false, journalWriterID: writer)
        try store.writeMetadata(Data("metadata".utf8), itemID: 1)
        try store.writeMedia(Data([1]), itemID: 1, plaintextExtension: "jpeg")
        #expect(try journal.snapshot().changes(since: initial) == ["1.json", "1.jpeg"])
        let beforeDelete = try journal.snapshot()
        store.removeItem(itemID: 1, plaintextExtension: "jpeg")
        #expect(try journal.snapshot().changes(since: beforeDelete) == ["1.json", "1.jpeg"])
        #expect(!FileManager.default.fileExists(atPath: store.metadataURL(itemID: 1).path))
        let legacy = LibraryFileStore(itemsDirectory: root, crypto: nil, journalWriterID: writer)
        let beforeLegacy = try journal.snapshot()
        try legacy.writeAux(Data("album".utf8), name: "album-test.json")
        #expect(try journal.snapshot().changes(since: beforeLegacy) == ["album-test.json"])
    }

    @Test func bulkDeleteUsesOneJournalTransactionForEveryFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = UUID().uuidString
        let journal = LibraryChangeJournal(root: root, writerID: writer)
        try journal.prepare()
        let store = LibraryFileStore(itemsDirectory: root, crypto: nil,
            createsContainerDirectory: false, journalWriterID: writer)
        for itemID in [1, 2] {
            try Data("metadata".utf8).write(to: store.metadataURL(itemID: itemID))
            try Data([1]).write(to: store.mediaURL(itemID: itemID, plaintextExtension: "jpeg"))
        }
        let before = try journal.snapshot()

        store.removeItems(itemIDs: [1, 2], plaintextExtensions: ["jpeg", "mp4"])

        let after = try journal.snapshot()
        let document = try #require(after.writers[writer + ".json"])
        #expect(document.sequence == (before.writers[writer + ".json"]?.sequence ?? 0) + 1)
        #expect(after.changes(since: before) == ["1.jpeg", "1.json", "2.jpeg", "2.json"])
        #expect(document.pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.metadataURL(itemID: 1).path))
        #expect(!FileManager.default.fileExists(atPath: store.mediaURL(itemID: 2, plaintextExtension: "jpeg").path))
    }

    @Test func gapsCorruptionAndMissingWritersRequireAudit() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = LibraryChangeJournal(root: root, writerID: UUID().uuidString)
        try journal.withMutation(names: ["1.json"]) {}
        let baseline = try journal.snapshot()
        var gap = baseline
        let key = try #require(gap.writers.keys.first)
        gap.writers[key]?.sequence = 600
        gap.writers[key]?.entries = [.init(sequence: 600, names: ["2.json"])]
        #expect(gap.changes(since: baseline) == nil)
        #expect(LibraryChangeJournal.Snapshot(writers: [:]).changes(since: baseline) == nil)
        try Data("broken".utf8).write(to: journal.directory.appendingPathComponent(key))
        #expect(throws: (any Error).self) { try journal.snapshot() }
        try journal.withMutation(names: ["recovered.json"]) {}
        #expect(try journal.snapshot().changes(since: baseline) == nil,
            "resetting a damaged log must invalidate old cursors")
    }

    @Test func failedMutationStillPublishesAffectedNames() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = LibraryChangeJournal(root: root, writerID: UUID().uuidString)
        try journal.withMutation(names: []) {}
        let initial = try journal.snapshot()
        enum Failure: Error { case interrupted }
        #expect(throws: Failure.self) {
            try journal.withMutation(names: ["1.json"]) { throw Failure.interrupted }
        }
        #expect(try journal.snapshot().changes(since: initial) == ["1.json"])
        #expect(throws: (any Error).self) { try journal.withMutation(names: ["../outside"]) {} }
    }
}
