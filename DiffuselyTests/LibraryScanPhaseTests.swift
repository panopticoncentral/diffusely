import Testing
import Foundation
@testable import Diffusely

/// `downloadStatus`'s presence check used to be an unconditional `fileExists`
/// per media file. Measured against the user's real network-mounted iCloud
/// share: 26.91 ms/file, 219.36s across 8,151 items — 27.8% of the whole
/// scan — because `fileExists(atPath:)` bypasses the resource-value cache the
/// directory listing already prefetched and issues a fresh metadata round
/// trip instead. `scanContainer` now resolves presence from that listing's
/// filenames (`presentNames`) instead of statting each file again; the
/// ubiquity-status logic that follows (load-bearing for the encrypted iCloud
/// root) is untouched.
///
/// Also covers `scanContainer`'s classify/read phase split (Phase A
/// classifies every sidecar serially, Phase B reads/decodes the queue Phase
/// A built). Named `Phase`, not `Concurrency`: a concurrent Phase B was
/// tried and reverted (measured slightly WORSE than serial on the real
/// network share — see `scanContainer`'s doc comment), so there is no
/// concurrency left here to test.
@Suite struct LibraryScanPhaseTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func metadataJSON(itemID: Int, mediaFileName: String) throws -> Data {
        try LibraryItemMetadata.encoder().encode(LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: itemID,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: mediaFileName,
            fileByteSize: 10, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t"
        ))
    }

    // MARK: - downloadStatus presence resolution

    /// The strongest form of "doesn't touch the filesystem": the file named
    /// by `mediaURL` is never written to disk at all, yet its name is
    /// supplied via `presentNames`. No implementation that secretly falls
    /// back to (or additionally performs) a `fileExists` stat could pass this
    /// — the real file is absent, so a stat would report `.evicted`.
    @Test func downloadStatusTrustsSuppliedNamesOverAFileThatDoesNotExistOnDisk() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaURL = dir.appendingPathComponent("1.jpeg")
        // Deliberately never written to `dir` — `fileExists` on this path is false.

        let status = LibraryIndexService.downloadStatus(
            for: mediaURL, fileManager: .default, presentNames: [mediaURL.lastPathComponent]
        )

        #expect(status != .evicted, "membership in presentNames must resolve presence without a filesystem check")
    }

    /// The other half of the contract: a supplied set that OMITS a file which
    /// genuinely exists on disk still reports `.evicted` — proving the set,
    /// not `fileExists`, governs the result.
    @Test func downloadStatusReportsEvictedForANameAbsentFromSuppliedNames() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mediaURL = dir.appendingPathComponent("1.jpeg")
        try Data("fake image bytes".utf8).write(to: mediaURL)

        let status = LibraryIndexService.downloadStatus(
            for: mediaURL, fileManager: .default, presentNames: []
        )

        #expect(status == .evicted)
    }

    /// `nil` — every caller besides `scanContainer` — must be byte-identical
    /// to the original always-`fileExists` behaviour.
    @Test func downloadStatusFallsBackToFileExistsWhenNoNamesAreSupplied() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missingURL = dir.appendingPathComponent("absent.jpeg")

        let status = LibraryIndexService.downloadStatus(for: missingURL, fileManager: .default)

        #expect(status == .evicted)
    }

    // MARK: - Scan parity

    /// A scan over a seeded directory must report identical statuses whether
    /// presence comes from the listing shortcut (`scanContainer`'s normal
    /// path, exercised here) or from a direct `fileExists` per file (the
    /// pre-existing behaviour, reproduced by calling `downloadStatus` with
    /// `presentNames: nil` against the same on-disk layout).
    @Test func scanProducesIdenticalStatusesWithAndWithoutTheListingShortcut() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)

        try store.writeMetadata(metadataJSON(itemID: 1, mediaFileName: "1.jpeg"), itemID: 1)
        try store.writeMedia(Data("bytes".utf8), itemID: 1, plaintextExtension: "jpeg")
        // Item 2's sidecar exists but its media was never downloaded/was evicted.
        try store.writeMetadata(metadataJSON(itemID: 2, mediaFileName: "2.jpeg"), itemID: 2)

        let scan = try #require(LibraryIndexService.scanContainer(
            store: store,
            isPlaceholder: { _ in false }
        ))
        let scannedStatuses = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.metadata.itemID, $0.status) })
        #expect(scannedStatuses.count == 2)

        let fileManager = FileManager.default
        for itemID in [1, 2] {
            let mediaURL = store.mediaURL(itemID: itemID, plaintextExtension: "jpeg")
            let statusWithoutShortcut = LibraryIndexService.downloadStatus(for: mediaURL, fileManager: fileManager)
            #expect(
                scannedStatuses[itemID] == statusWithoutShortcut,
                "item \(itemID) status must match between the listing shortcut and the fileExists path"
            )
        }
    }

    // MARK: - Classify/read split parity
    //
    // `scanContainer` was refactored to classify every sidecar (Phase A)
    // before reading/decoding any of them (Phase B). These tests pin the
    // output — one complete item per id, the unreadable sidecar preserved
    // rather than pruned, the album counted, and a stable item order —
    // across that classification/read split.

    /// Seeds `count` complete items plus one album file, one unreadable sidecar
    /// and one foreign file, and returns the directory.
    private func seed(count: Int) throws -> URL {
        let dir = tempDir()
        for id in 1...count {
            let metadata = makeMetadata(itemID: id)
            try LibraryItemMetadata.encoder().encode(metadata)
                .write(to: dir.appendingPathComponent("\(id).json"))
            try Data("m".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }
        // A minimal-but-valid album file: `{}` doesn't decode as
        // `LibraryAlbumFile` (it requires `id`/`name`/`createdAt`), which
        // would silently drop it from `albums` — this pins the actually
        // decodable case instead.
        let album = LibraryAlbumFile(id: UUID(), name: "Test Album", createdAt: Date())
        try LibraryAlbumFile.encoder().encode(album)
            .write(to: dir.appendingPathComponent(LibraryAlbumStore.fileName(for: album.id)))
        // Present but undecodable: must be counted as seen, never pruned.
        try Data("not json".utf8).write(to: dir.appendingPathComponent("999.json"))
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        return dir
    }

    @Test func scanFindsEveryItemAndPreservesTheUnreadableOne() throws {
        let dir = try seed(count: 25)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)

        let scan = try #require(LibraryIndexService.scanContainer(store: store))

        #expect(scan.items.count == 25)
        #expect(scan.seenIDs.count == 26, "the undecodable sidecar must still be seen, not pruned")
        #expect(scan.seenIDs.contains(999))
        #expect(scan.albums.count == 1)
    }

    /// `scan.items` ordering must track Phase A's classification order, not
    /// whatever order Phase B happens to produce results in — a concurrent
    /// Phase B was tried and reverted (see `scanContainer`'s doc comment),
    /// but the ordering guarantee is worth guarding regardless of whether
    /// Phase B is concurrent, since a future change to that loop could just
    /// as easily reorder it by accident. Running the scan twice and
    /// comparing only catches a reordering regression by luck — two runs can
    /// just as easily agree by chance. Instead this pins `scan.items`
    /// against the order Phase A's classification actually produced: a
    /// single independent directory listing, filtered to item sidecars and
    /// mapped to the ids that decode successfully (excluding the album file
    /// and the deliberately-undecodable `999.json` from `seed`). That
    /// listing and the one `scanContainer` takes internally are both single,
    /// unmodified reads of the same on-disk directory, so they enumerate
    /// identically — a Phase B that appended by any order other than
    /// classification order would diverge from this every time.
    @Test func scanReturnsItemsInTheClassificationPhasesEnumerationOrder() throws {
        let count = 40
        let dir = try seed(count: count)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let validIDs = Set(1...count)

        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: LibraryIndexService.scanPrefetchKeys
        )
        let expectedOrder = contents
            .filter { store.isMetadataFileName($0.lastPathComponent) }
            .filter { LibraryAlbumStore.albumID(fromFileName: $0.lastPathComponent) == nil }
            .compactMap { store.itemID(forMetadataFile: $0) }
            .filter { validIDs.contains($0) }
        #expect(expectedOrder.count == count, "seed's decodable items must all be represented in the reference order")

        let scan = try #require(LibraryIndexService.scanContainer(store: store))

        #expect(scan.items.map(\.metadata.itemID) == expectedOrder)
    }
}
