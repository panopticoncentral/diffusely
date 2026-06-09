import Testing
import Foundation
import SwiftData
@testable import Diffusely

@MainActor
@Suite struct LibraryStoreAlbumTests {
    @Test func storeExposesAlbumServiceAndBumpsVersion() async throws {
        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let store = LibraryStore(modelContainer: container)
        let before = store.albumsVersion
        store.notifyAlbumsChanged()
        #expect(store.albumsVersion == before + 1)
        #expect(store.albumService != nil)
    }
}
