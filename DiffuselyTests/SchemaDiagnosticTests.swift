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
        let config = ModelConfiguration(schema: schema, url: url)
        _ = try ModelContainer(for: schema, configurations: [config])
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
        let config = ModelConfiguration(schema: schema, url: url)
        _ = try ModelContainer(for: schema, configurations: [config])
    }
}
