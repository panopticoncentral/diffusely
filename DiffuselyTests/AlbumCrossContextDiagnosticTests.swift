import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// Diagnostic: does the LONG-LIVED main context (what the app's LibrarySortService
/// reads from) see a PersistedAlbum inserted by the LibraryIndexService @ModelActor's
/// SEPARATE context? Mirrors the app exactly (container.mainContext), unlike the
/// other album tests which assert via a fresh ModelContext(container).
@MainActor
@Suite struct AlbumCrossContextDiagnosticTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @Test func mainContextSeesAlbumWrittenByIndexActor() async throws {
        let container = try makeContainer()
        let mainContext = container.mainContext               // exactly what the app uses
        let sortService = LibrarySortService(modelContext: mainContext)

        #expect(sortService.albumSummaries().isEmpty)         // none yet

        let index = LibraryIndexService(modelContainer: container)
        await index.upsertAlbum(LibraryAlbumFile(id: UUID(), name: "X", createdAt: Date(timeIntervalSince1970: 1)))

        // The actor saved on ITS context. Does the long-lived main context see it?
        let summaries = sortService.albumSummaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.name == "X")
    }

    /// Same as above but against an ON-DISK store (what the app actually uses).
    /// In-memory stores share backing across contexts; on-disk stores can leave a
    /// long-lived context that already fetched serving a stale cached result when
    /// another context inserts rows. This reproduces the real app configuration.
    @Test func onDiskMainContextSeesAlbumWrittenByIndexActor() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
        let mainContext = container.mainContext
        let sortService = LibrarySortService(modelContext: mainContext)

        // Prime the main context's query cache with an empty result first.
        #expect(sortService.albumSummaries().isEmpty)

        let index = LibraryIndexService(modelContainer: container)
        await index.upsertAlbum(LibraryAlbumFile(id: UUID(), name: "X", createdAt: Date(timeIntervalSince1970: 1)))

        let summaries = sortService.albumSummaries()
        #expect(summaries.count == 1)        // <-- does the on-disk main context see it?
        #expect(summaries.first?.name == "X")
    }
}
