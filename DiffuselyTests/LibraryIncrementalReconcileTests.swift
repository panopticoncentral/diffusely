import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// Task 3 of the network-root scan performance work: every ingest records the
/// sidecar's fingerprint (name, `contentModificationDate`, `fileSize`) so a
/// later reconcile can compare it against the directory listing instead of
/// re-reading the file. This task only records the fingerprint — nothing
/// consumes it yet — but a wrong or missing fingerprint here would make the
/// eventual skip either silently blind (never records => always re-reads,
/// merely slow) or wrong (a stale value => a real change gets skipped), so
/// the fingerprint recorded by a scan must match the file actually on disk.
@Suite struct LibraryIncrementalReconcileTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMeta(itemID: Int) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: itemID,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 10, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "t"
        )
    }

    /// A reconcile that ingests a sidecar must record the fingerprint the
    /// directory listing actually saw for it — not a stat gathered
    /// separately, since a second per-file stat is exactly the 219-second
    /// mistake this plan already fixed once. Comparing against the file's own
    /// resource values (read directly here, not through the scan) is what
    /// proves the recorded fingerprint is real rather than a placeholder.
    @Test func reconcileRecordsTheIngestedSidecarsFingerprint() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(
            LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1)), itemID: 1)

        let sidecarURL = dir.appendingPathComponent("1.json")
        let onDisk = try sidecarURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let expectedModifiedAt = try #require(onDisk.contentModificationDate)
        let expectedByteSize = try #require(onDisk.fileSize)

        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let index = LibraryIndexService(modelContainer: container)

        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })

        let rows = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        let row = try #require(rows.first(where: { $0.itemID == 1 }))
        #expect(row.sidecarFileName == "1.json", "the name the scan actually saw, not a derived one")
        #expect(row.sidecarModifiedAt == expectedModifiedAt)
        #expect(row.sidecarByteSize == expectedByteSize)
    }

    /// A row updated by a later reconcile (not just inserted) must also carry
    /// the fresh fingerprint through `apply(_:downloadStatus:to:)`, not only
    /// through the `PersistedLibraryItem` initializer used for new rows.
    @Test func reconcileRefreshesTheFingerprintOnAnExistingRow() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(
            LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1)), itemID: 1)

        let container = try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })

        // Rewrite the sidecar so its modification date moves. A short delay
        // (not a blocking sleep, to avoid starving the cooperative pool) is
        // enough margin for the filesystem's mtime clock to visibly advance.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try store.writeMetadata(
            LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1)), itemID: 1)
        let sidecarURL = dir.appendingPathComponent("1.json")
        let onDisk = try sidecarURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let expectedModifiedAt = try #require(onDisk.contentModificationDate)

        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })

        let rows = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        let row = try #require(rows.first(where: { $0.itemID == 1 }))
        #expect(row.sidecarModifiedAt == expectedModifiedAt, "the second reconcile's fingerprint, not the first's")
    }

    /// A row inserted before this field existed defaults to the empty/unknown
    /// state — never a value that happens to collide with a real file. This
    /// is what makes "unknown" a safe default for Task 4's skip logic.
    @Test func aFreshlyConstructedRowDefaultsToTheUnknownFingerprint() {
        let row = PersistedLibraryItem(metadata: makeMeta(itemID: 1), downloadStatus: .downloaded)
        #expect(row.sidecarFileName == "")
        #expect(row.sidecarModifiedAt == nil)
        #expect(row.sidecarByteSize == 0)
    }

    // MARK: - Task 4: skip unchanged sidecars

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func writeItemSidecar(_ id: Int, in dir: URL) throws {
        let data = try LibraryItemMetadata.encoder().encode(makeMeta(itemID: id))
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    private func makeMeta(itemID: Int, username: String, savedAt: Date) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: itemID,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 10, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: username, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: savedAt, savedByAppVersion: "t"
        )
    }

    /// The rule this whole task lives or dies by: a sidecar that is skipped
    /// because it has not changed is still PRESENT, so its row must survive.
    /// If skipped ids stop reaching seenIDs, reconcile prunes the entire
    /// unchanged Library -- the exact failure the eviction-sweep guards exist
    /// to prevent.
    ///
    /// Checked two ways deliberately, because either alone is insufficient:
    /// surviving rows alone would also pass an implementation that skips
    /// nothing (never actually exercising the skip path), and "nothing was
    /// read" alone would pass an implementation that wrongly prunes
    /// everything (an empty index has nothing left to read either).
    @Test func unchangedSidecarsAreSkippedButTheirRowsSurvive() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for id in 1...30 { try writeItemSidecar(id, in: dir) }

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        // First pass: nothing indexed yet, so every sidecar must be read to
        // be ingested at all.
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let seededCount = await index.itemCount()
        #expect(seededCount == 30, "precondition: every seeded sidecar must have been ingested")

        // Second pass: nothing on disk changed. Half of the proof: the rows
        // must all still be there afterward.
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let countAfterSecondReconcile = await index.itemCount()
        #expect(countAfterSecondReconcile == 30,
                "unchanged rows must survive a reconcile that skips reading them")

        // Other half of the proof: replay byte-for-byte what that second
        // reconcile() call did internally -- same directory, same
        // fingerprints the index now holds, nothing changed in between -- so
        // the resulting scan's own metrics can be inspected directly.
        let fingerprints = await index.indexedFingerprints()
        #expect(fingerprints.count == 30, "precondition: every row must have recorded a fingerprint")
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let scan = try #require(LibraryIndexService.scanContainer(
            store: store, isPlaceholder: { _ in false }, fingerprints: fingerprints
        ))
        #expect(scan.metrics.sidecarsRead == 0, "an unchanged sidecar must never be read")
        #expect(scan.items.isEmpty, "an unchanged sidecar never produces a Phase B result")
        #expect(scan.seenIDs.count == 30, "every skipped id must still be reported seen, or reconcile prunes it")
        #expect(scan.statusUpdates.count == 30, "status must still be refreshed for every skipped row")
    }

    /// A sidecar whose fingerprint no longer matches what was recorded must
    /// never be skipped, even though its name is in the map. Byte size is
    /// changed here (not just mtime) so the assertion doesn't depend on
    /// filesystem mtime resolution.
    @Test func aChangedFingerprintForcesAReread() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.writeMetadata(
            LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1, username: "a", savedAt: savedAt)),
            itemID: 1)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })

        // Rewrite with a longer username: the byte size changes, so the
        // fingerprint recorded by the first scan can never match this scan's
        // listing.
        try store.writeMetadata(
            LibraryItemMetadata.encoder().encode(makeMeta(itemID: 1, username: "a-much-longer-username", savedAt: savedAt)),
            itemID: 1)

        let fingerprints = await index.indexedFingerprints()
        let scan = try #require(LibraryIndexService.scanContainer(
            store: store, isPlaceholder: { _ in false }, fingerprints: fingerprints
        ))
        #expect(scan.metrics.sidecarsRead == 1, "a changed sidecar must be read, not skipped")
        #expect(scan.items.count == 1)
        #expect(scan.items.first?.metadata.itemID == 1)
    }

    /// A brand-new sidecar the index has never seen has no entry in the
    /// fingerprint map at all, so it must always be read and ingested.
    @Test func aNewSidecarWithNoRecordedFingerprintIsRead() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeItemSidecar(1, in: dir)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let fingerprintsBeforeNewFile = await index.indexedFingerprints()
        #expect(fingerprintsBeforeNewFile.count == 1)

        // A second sidecar lands with no recorded fingerprint -- it was never
        // indexed before, so it must be read, while item 1 (unchanged) is
        // skipped.
        try writeItemSidecar(2, in: dir)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let scan = try #require(LibraryIndexService.scanContainer(
            store: store, isPlaceholder: { _ in false }, fingerprints: fingerprintsBeforeNewFile
        ))
        #expect(scan.metrics.sidecarsRead == 1, "only the brand-new sidecar should be read")
        #expect(scan.items.count == 1)
        #expect(scan.items.first?.metadata.itemID == 2)
        #expect(scan.seenIDs == Set([1, 2]))
    }

    /// A sidecar that genuinely vanished must still be pruned, even while
    /// other rows in the same reconcile are being skipped via matching
    /// fingerprints -- the two mechanisms must not interfere with each other.
    @Test func aDeletedSidecarIsPrunedEvenWhileOthersAreSkipped() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeItemSidecar(1, in: dir)
        try writeItemSidecar(2, in: dir)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        #expect(await index.itemCount() == 2)

        // Item 1's sidecar vanishes; item 2's is untouched and will be
        // skipped via its matching fingerprint. Pruning must still catch
        // item 1.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("1.json"))
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })

        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(items.count == 1)
        #expect(items.first?.itemID == 2)
    }

    /// Rule 2: the fingerprint covers the SIDECAR, not the media. A skipped
    /// sidecar's row must still get a fresh download status from the
    /// listing, or an item whose media was evicted since the last scan keeps
    /// a stale "downloaded" badge forever.
    @Test func skippedSidecarsStillRefreshDownloadStatusFromTheListing() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeItemSidecar(1, in: dir)
        try Data("img".utf8).write(to: dir.appendingPathComponent("1.jpeg"))

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let rowsAfterFirst = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(rowsAfterFirst.first?.downloadStatus == .downloaded,
                "precondition: media is present, so status starts downloaded")

        // Media evicted since the last scan; the sidecar itself is
        // untouched, so its fingerprint still matches and it gets skipped.
        // Status must still flip, because it's read fresh from the listing,
        // not derived from the (unread) sidecar.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("1.jpeg"))
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })

        let rowsAfterSecond = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(rowsAfterSecond.first?.downloadStatus == .evicted,
                "a skipped sidecar must still get a fresh status from the listing")
    }

    /// The other half of Rule 2: when the media file is genuinely PRESENT in
    /// the listing (the eviction test above only exercises the absent
    /// case), the skip branch's lookup must still resolve it. That lookup is
    /// built from the row's stored `mediaFileName` (Change 3's replacement
    /// for a deleted per-scan `mediaExtensionByItemID` guess that took the
    /// extension from whichever same-stem file the listing happened to see
    /// last) — if that value ever fails to produce the same name the
    /// listing has an entry for, a skipped-but-still-downloaded item would
    /// wrongly flip to `.evicted`.
    @Test func skippedSidecarsResolvePresentMediaThroughTheStoredFileName() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeItemSidecar(1, in: dir)
        try Data("img".utf8).write(to: dir.appendingPathComponent("1.jpeg"))

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let rowsAfterFirst = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(rowsAfterFirst.first?.downloadStatus == .downloaded,
                "precondition: media is present, so status starts downloaded")

        // Replay what a second, nothing-changed reconcile does internally so
        // the skip is provable, not just plausible: the sidecar's recorded
        // fingerprint still matches this listing, so it must be skipped
        // (not re-read) while its media -- still sitting right there in the
        // directory -- resolves to `.downloaded` through the skip branch's
        // own lookup.
        let fingerprints = await index.indexedFingerprints()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        let scan = try #require(LibraryIndexService.scanContainer(
            store: store, isPlaceholder: { _ in false }, fingerprints: fingerprints
        ))
        #expect(scan.metrics.sidecarsRead == 0, "the unchanged sidecar must be skipped, not re-read")
        #expect(scan.statusUpdates.count == 1)
        #expect(scan.statusUpdates.first?.status == .downloaded,
                "the skip branch must resolve the still-present media file, not wrongly report it evicted")
    }

    /// rebuild(itemsDirectory:) must ignore fingerprints entirely -- "Rebuild
    /// Index" means "distrust the index", so it must never consult the very
    /// fingerprints it exists to rebuild. Proven by making the on-disk
    /// sidecar disagree with the index while keeping the RECORDED
    /// fingerprint (name/mtime/size) matching: a plain reconcile() must
    /// skip the read and leave the stale field in place, while rebuild()
    /// must re-read and heal it.
    @Test func rebuildIgnoresFingerprintsEntirely() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecarURL = dir.appendingPathComponent("1.json")
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedModDate = Date(timeIntervalSince1970: 1_700_000_100)

        let correctData = try LibraryItemMetadata.encoder().encode(
            makeMeta(itemID: 1, username: "correct", savedAt: savedAt))
        try correctData.write(to: sidecarURL)
        try FileManager.default.setAttributes([.modificationDate: fixedModDate], ofItemAtPath: sidecarURL.path)

        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let afterSeed = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(afterSeed.first?.authorUsername == "correct", "precondition")

        // Replace the sidecar's content with a same-length (so same byte
        // size), same-mtime replacement -- an artificial but precise way to
        // force the recorded fingerprint to still match while the actual
        // content disagrees with the index.
        let damagedData = try LibraryItemMetadata.encoder().encode(
            makeMeta(itemID: 1, username: "damaged", savedAt: savedAt))
        #expect(damagedData.count == correctData.count,
                "precondition: the replacement must be byte-identical in size")
        try damagedData.write(to: sidecarURL)
        try FileManager.default.setAttributes([.modificationDate: fixedModDate], ofItemAtPath: sidecarURL.path)

        // A plain reconcile: the fingerprint still matches, so this must
        // skip the read and leave the stale "correct" value in place.
        await index.reconcile(itemsDirectory: dir, isPlaceholder: { _ in false })
        let afterSkippedReconcile = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(afterSkippedReconcile.first?.authorUsername == "correct",
                "a matching fingerprint must skip the read, leaving the stale field untouched")

        // rebuild: must ignore the (still-matching) fingerprint and heal the
        // field back to what's actually on disk.
        await index.rebuild(itemsDirectory: dir)
        let afterRebuild = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(afterRebuild.first?.authorUsername == "damaged",
                "rebuild must ignore fingerprints and always re-read")
    }
}
