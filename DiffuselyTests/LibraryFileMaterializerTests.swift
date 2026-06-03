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

    /// A missing, non-ubiquitous target has nothing to materialize, so `download`
    /// must fail fast instead of calling `startDownloadingUbiquitousItem` (which,
    /// for a path inside the iCloud container, spawns a doomed `LocalDownloadTask`
    /// that fails -1002 "unsupported URL" keyed by the iCloud document UUID and
    /// re-fires on every grid/video reappearance). The throw must be prompt — not
    /// the ~2-minute poll ceiling.
    @Test func downloadFailsFastForNonUbiquitousMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mat-download-missing-\(UUID().uuidString).bin")
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await LibraryFileMaterializer.download(url: url)
        }
        // Comfortably under the first poll tick (0.5s); proves we never entered
        // the materialization poll loop.
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
