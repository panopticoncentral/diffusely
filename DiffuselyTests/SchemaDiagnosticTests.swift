import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite struct SchemaDiagnosticTests {
    @Test func fullSchemaBuildsOnDisk() throws {
        let schema = Schema([
            PersistedCollection.self,
            PersistedAuthor.self,
            PersistedImage.self,
            PersistedPost.self,
            PersistedPostImage.self,
            PersistedLibraryItem.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).store")
        defer {
            for s in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + s)
            }
        }
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        _ = try ModelContainer(for: schema, configurations: [config])
    }

    @Test func persistedCollectionListFieldsRoundTripOnDisk() throws {
        let schema = Schema([
            PersistedCollection.self, PersistedAuthor.self, PersistedImage.self,
            PersistedPost.self, PersistedPostImage.self, PersistedLibraryItem.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).store")
        defer {
            for s in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + s)
            }
        }
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let row = PersistedCollection(id: 4242, name: "Disk", collectionType: "Post")
        row.collectionDescription = "desc"
        row.imageCount = 11
        row.coverImageId = 7
        row.coverImageRelativePath = "rel/path"
        row.isInUserList = true
        row.listOrder = 3
        row.listSyncGeneration = 9
        row.lastSeenListGeneration = 9
        row.lastListSyncCompleted = Date(timeIntervalSince1970: 5000)
        context.insert(row)
        try context.save()

        let fetched = try ModelContext(container).fetch(
            FetchDescriptor<PersistedCollection>(predicate: #Predicate { $0.id == 4242 })
        ).first
        #expect(fetched?.collectionDescription == "desc")
        #expect(fetched?.imageCount == 11)
        #expect(fetched?.coverImageId == 7)
        #expect(fetched?.isInUserList == true)
        #expect(fetched?.listOrder == 3)
        #expect(fetched?.lastListSyncCompleted == Date(timeIntervalSince1970: 5000))
    }

    @Test func libraryItemOnlyOnDisk() throws {
        let schema = Schema([PersistedLibraryItem.self])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).store")
        defer {
            for s in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + s)
            }
        }
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        _ = try ModelContainer(for: schema, configurations: [config])
    }
}
