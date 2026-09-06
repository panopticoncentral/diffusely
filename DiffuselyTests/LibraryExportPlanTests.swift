import XCTest
@testable import Diffusely

final class LibraryExportPlanTests: XCTestCase {
    private func makeDestination() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ dir: URL, _ name: String) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func row(_ id: Int, bytes: Int, evicted: Bool, ext: String = "jpeg") -> LibraryExportSizingRow {
        LibraryExportSizingRow(itemID: id, mediaFileName: "\(id).\(ext)",
                               fileByteSize: bytes, isEvicted: evicted)
    }

    func testCountsEverythingWhenDestinationIsEmpty() throws {
        let destination = try makeDestination()
        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 100, evicted: true), row(2, bytes: 50, evicted: false)],
            availableBytes: 10_000)

        XCTAssertEqual(plan.itemsToExport, 2)
        XCTAssertEqual(plan.alreadyExported, 0)
        XCTAssertEqual(plan.bytesToDownload, 100)   // only the evicted one
        XCTAssertEqual(plan.bytesToWrite, 150)      // both
        XCTAssertTrue(plan.fitsOnDisk)
    }

    func testItemNeedsBothFilesPresentToCountAsExported() throws {
        let destination = try makeDestination()
        try touch(destination, "1.jpeg")
        try touch(destination, "1.json")
        try touch(destination, "2.jpeg")            // media only — not done

        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 100, evicted: true), row(2, bytes: 50, evicted: true)],
            availableBytes: 10_000)

        XCTAssertEqual(plan.alreadyExported, 1)
        XCTAssertEqual(plan.itemsToExport, 1)
        XCTAssertEqual(plan.bytesToDownload, 50)
        XCTAssertEqual(plan.bytesToWrite, 50)
    }

    func testVideoRowsUseTheirOwnExtension() throws {
        let destination = try makeDestination()
        try touch(destination, "7.mp4")
        try touch(destination, "7.json")

        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(7, bytes: 900, evicted: true, ext: "mp4")],
            availableBytes: 10_000)

        XCTAssertEqual(plan.alreadyExported, 1)
        XCTAssertEqual(plan.itemsToExport, 0)
        XCTAssertEqual(plan.bytesToWrite, 0)
    }

    func testDoesNotFitWhenBytesToWriteExceedAvailable() throws {
        let destination = try makeDestination()
        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 5_000, evicted: false)],
            availableBytes: 1_000)

        XCTAssertFalse(plan.fitsOnDisk)
        XCTAssertEqual(plan.bytesToWrite, 5_000)
        // Locally-present items still count against free space even though
        // nothing needs downloading.
        XCTAssertEqual(plan.bytesToDownload, 0)
    }

    // MARK: Free-space probing

    /// Unknown capacity is not "full": the two are reported differently, so
    /// a volume that reports neither key can't masquerade as a full disk.
    func testUnknownCapacityIsDistinguishedFromAFullDisk() throws {
        let destination = try makeDestination()
        let plan = LibraryExportPlanner.plan(
            destination: destination,
            rows: [row(1, bytes: 5_000, evicted: false)],
            availableBytes: nil)

        XCTAssertTrue(plan.capacityUnknown)
        XCTAssertFalse(plan.fitsOnDisk)
        XCTAssertNil(plan.availableBytes)
    }

    /// The refusal must say capacity couldn't be measured, not claim the
    /// destination is full — an exFAT/SMB volume that returns nil for
    /// `volumeAvailableCapacityForImportantUsage` used to be reported as
    /// "only Zero bytes is available" on a 4 TB drive.
    func testCapacityUnknownRefusalSaysSoRatherThanClaimingZeroBytes() {
        let message = LibraryExportError
            .capacityUnknown(needed: 41_000_000_000, path: "/Volumes/Backup")
            .errorDescription ?? ""

        XCTAssertTrue(message.lowercased().contains("couldn't determine"), message)
        XCTAssertTrue(message.contains("/Volumes/Backup"), message)
        XCTAssertFalse(message.contains("Zero bytes"), message)
    }

    /// A real local volume answers the primary key; the fallback exists for
    /// the ones that don't, and neither path may return nil here.
    func testAvailableCapacityReadsARealVolume() throws {
        let destination = try makeDestination()
        let capacity = try XCTUnwrap(LibraryExportPlanner.availableCapacity(at: destination))
        XCTAssertGreaterThan(capacity, 0)
    }

    /// A URL on no volume at all (nothing there to interrogate) is the only
    /// remaining nil case, and it must be nil rather than 0.
    func testAvailableCapacityIsNilWhenNoVolumeAnswers() {
        let nowhere = URL(fileURLWithPath: "/dev/null/not-a-volume/\(UUID().uuidString)")
        XCTAssertNil(LibraryExportPlanner.availableCapacity(at: nowhere))
    }

    // MARK: availableCapacity fallback (injected key lookup)
    //
    // A temp directory is always APFS, where the primary key answers a
    // positive number and the fallback path never runs — so none of the
    // fallback shapes below (nil primary, zero primary, both failing) are
    // reachable through a real volume in this test environment. The key
    // lookup is injected here to exercise them directly; an implementation
    // that deleted the fallback would still pass every other test in this
    // file because they never touch a non-APFS volume.

    private func stubbedCapacity(
        important: Int64?, plain: Int?
    ) -> (URL) -> (important: Int64?, plain: Int?) {
        { _ in (important, plain) }
    }

    /// The common case: the primary key answers a usable positive number, and
    /// the fallback is never needed.
    func testAvailableCapacityUsesThePrimaryKeyWhenItAnswersAPositiveNumber() {
        let capacity = LibraryExportPlanner.availableCapacity(
            at: URL(fileURLWithPath: "/irrelevant"),
            readCapacities: stubbedCapacity(important: 4_000_000_000_000, plain: 1))

        XCTAssertEqual(capacity, 4_000_000_000_000)
    }

    /// The original fallback shape: the primary key answers nil (as
    /// `volumeAvailableCapacityForImportantUsage` does on plenty of exFAT/SMB
    /// volumes), so the plain key is consulted instead.
    func testAvailableCapacityFallsBackWhenThePrimaryKeyIsNil() {
        let capacity = LibraryExportPlanner.availableCapacity(
            at: URL(fileURLWithPath: "/irrelevant"),
            readCapacities: stubbedCapacity(important: nil, plain: 4_000_000_000_000))

        XCTAssertEqual(capacity, 4_000_000_000_000)
    }

    /// The gap this fix closes: some exFAT/SMB volumes answer the primary key
    /// with a bare 0 instead of nil. Before the fix that 0 stood as the
    /// answer and the export hard-refused a drive with terabytes free; now a
    /// zero important-usage figure falls back to the plain key exactly like a
    /// nil one does.
    func testAvailableCapacityFallsBackWhenThePrimaryKeyAnswersZero() {
        let capacity = LibraryExportPlanner.availableCapacity(
            at: URL(fileURLWithPath: "/irrelevant"),
            readCapacities: stubbedCapacity(important: 0, plain: 4_000_000_000_000))

        XCTAssertEqual(capacity, 4_000_000_000_000)
    }

    /// Both keys unreadable is still the one remaining nil case.
    func testAvailableCapacityIsNilWhenBothKeysFail() {
        let capacity = LibraryExportPlanner.availableCapacity(
            at: URL(fileURLWithPath: "/irrelevant"),
            readCapacities: { _ in (nil, nil) })

        XCTAssertNil(capacity)
    }
}
