import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// The feed's "already in your library" badge. Three pieces, tested here:
///
/// 1. `LibraryIndexService.summary()` — the single index read that backs the
///    badge. It folds the saved-ID set into the same full-table pass
///    `refreshTotals()` already made for the count and byte total, so the
///    badge costs no additional fetch.
/// 2. `LibrarySaveService.isSaved(itemID:)` — the O(1) per-cell lookup, which
///    must stay silent while the library isn't browsable: with an encrypted
///    vault locked, a badge would tell anyone holding the device which feed
///    items are in the locked library.
/// 3. `LibrarySaveService.showsSavedBadges(givenLibraryGate:)` — the pure gate
///    decision, mirroring `LibraryStore.shouldAutonomousReconcile`. Proven
///    directly rather than by driving the `LibraryVaultProvider.shared`
///    singleton, which would leak global state into every other test in the
///    process (the precedent documented on `LibraryStoreReconcileGateTests`).
@Suite struct LibrarySavedIndexSummaryTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func makeMetadata(itemID: Int, byteSize: Int = 1000) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: itemID,
            sourcePostID: nil,
            sourcePostTitle: nil,
            canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)",
            sourceDomain: "civitai.com",
            originalCDNURL: "https://image.civitai.com/x/uuid/original=true/\(itemID).jpeg",
            mediaType: .image,
            mediaFileName: "\(itemID).jpeg",
            fileByteSize: byteSize,
            contentSHA256: "deadbeef",
            width: 10,
            height: 10,
            nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil,
            generationData: nil,
            publishedAt: nil,
            savedAt: Date(),
            savedByAppVersion: "test"
        )
    }

    @Test func summaryReportsSavedItemIDs() async throws {
        let index = LibraryIndexService(modelContainer: try makeContainer())
        await index.ingest(metadata: makeMetadata(itemID: 11), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 22), downloadStatus: .evicted)

        #expect(await index.summary().savedItemIDs == [11, 22])
    }

    @Test func summaryDropsRemovedItemIDs() async throws {
        let index = LibraryIndexService(modelContainer: try makeContainer())
        await index.ingest(metadata: makeMetadata(itemID: 11), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 22), downloadStatus: .downloaded)

        await index.remove(itemID: 11)

        #expect(await index.summary().savedItemIDs == [22])
    }

    /// The count and byte total must match what the two separate fetches
    /// reported before they were folded into one pass — an evicted item's bytes
    /// are excluded from the downloaded total but it still counts as saved.
    @Test func summaryTotalsMatchTheStandaloneQueries() async throws {
        let index = LibraryIndexService(modelContainer: try makeContainer())
        await index.ingest(metadata: makeMetadata(itemID: 11, byteSize: 700), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 22, byteSize: 300), downloadStatus: .evicted)

        let summary = await index.summary()
        #expect(summary.itemCount == 2)
        #expect(summary.itemCount == (await index.itemCount()))
        #expect(summary.downloadedBytes == 700)
        #expect(summary.downloadedBytes == (await index.totalDownloadedBytes()))
    }
}

@Suite @MainActor struct LibrarySavedBadgeVisibilityTests {
    private func makeService() -> LibrarySaveService {
        let dir = FileManager.default.temporaryDirectory
        return LibrarySaveService(resolveVaultContext: {
            (.notConfigured, LibraryFileStore(itemsDirectory: dir, crypto: nil))
        })
    }

    @Test func savedItemShowsWhileBrowsable() {
        let svc = makeService()
        svc.setLibraryBrowsable(true)
        svc.setSavedItemIDs([5])

        #expect(svc.isSaved(itemID: 5))
        #expect(!svc.isSaved(itemID: 6))
    }

    /// The privacy rule: a locked library reveals nothing about its contents.
    @Test func savedItemStaysHiddenWhileNotBrowsable() {
        let svc = makeService()
        svc.setSavedItemIDs([5])
        svc.setLibraryBrowsable(false)

        #expect(!svc.isSaved(itemID: 5))
    }

    /// A just-completed save badges its cell immediately, without waiting for
    /// the next reconcile to push a fresh set in.
    @Test func markSavedBadgesTheItemImmediately() {
        let svc = makeService()
        svc.setLibraryBrowsable(true)

        svc.markSaved(itemID: 9)

        #expect(svc.isSaved(itemID: 9))
    }

    @Test func badgesShowOnlyWhileBrowsable() {
        #expect(LibrarySaveService.showsSavedBadges(givenLibraryGate: .browsable) == true)
        #expect(LibrarySaveService.showsSavedBadges(givenLibraryGate: .locked) == false)
        #expect(LibrarySaveService.showsSavedBadges(givenLibraryGate: .loading) == false)
        #expect(LibrarySaveService.showsSavedBadges(givenLibraryGate: .migrating) == false)
        #expect(LibrarySaveService.showsSavedBadges(givenLibraryGate: .setupIncomplete) == false)
    }
}
