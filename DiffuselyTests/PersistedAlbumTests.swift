import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct PersistedAlbumTests {
    @Test func insertsAndFetchesAlbum() throws {
        let container = try ModelContainer(
            for: PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let ctx = ModelContext(container)
        let id = UUID()
        ctx.insert(PersistedAlbum(id: id, name: "Faves", createdAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<PersistedAlbum>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.name == "Faves")
    }
}
