import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// FINDING 5. `didRunDateBackfillThisSession` / `didRunCheckpointBackfillThisSession`
/// are one-shot-per-session latches only because re-running the backfills
/// against the SAME Library would be pointless. A root switch makes that no
/// longer true — the folder being opened is a different set of items that has
/// never been backfilled in this process — so `quiesceForRootSwitch()` must
/// clear them. Leaving them latched meant a newly opened root (an exported
/// folder, the headline use case) got no publish-date and no checkpoint backfill
/// at all until the app was relaunched.
@MainActor
@Suite struct LibraryStoreQuiesceTests {
    private func makeStore() throws -> LibraryStore {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return LibraryStore(modelContainer: container)
    }

    @Test func quiesceResetsTheSessionBackfillLatches() async throws {
        let store = try makeStore()
        store.markDateBackfillRanThisSession()
        store.markCheckpointBackfillRanThisSession()
        #expect(store.didRunDateBackfillThisSession)
        #expect(store.didRunCheckpointBackfillThisSession)

        await store.quiesceForRootSwitch()

        #expect(store.didRunDateBackfillThisSession == false,
                "a newly opened root has never been date-backfilled in this session")
        #expect(store.didRunCheckpointBackfillThisSession == false,
                "a newly opened root has never been checkpoint-backfilled in this session")
    }

    /// The latches this quiesce already cleared stay cleared — asserted
    /// alongside so a future edit can't trade one reset for another.
    @Test func quiesceAlsoClearsReadinessAsBefore() async throws {
        let store = try makeStore()
        await store.quiesceForRootSwitch()
        #expect(store.isReady == false)
    }
}
