import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryFileMaterializerTests {
    @Test func readyForExistingLocalFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await LibraryFileMaterializer.isReady(url: url) == true)
    }

    @Test func notReadyForMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat-missing-\(UUID().uuidString).txt")
        #expect(await LibraryFileMaterializer.isReady(url: url) == false)
    }
}
