import XCTest
@testable import Diffusely

/// The pending-download count only moves when a reconcile runs, and reconciles
/// only run when the container changes — so a container that has stopped
/// downloading produces NO further updates. That's why "stalled" is derived
/// from a timestamp at read time rather than pushed: the UI can re-derive it on
/// a timer while nothing at all is arriving.
final class LibraryDownloadProgressTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNothingPendingIsIdle() {
        let progress = LibraryDownloadProgress().recording(pending: 0, now: t0)
        XCTAssertEqual(progress.state(now: t0), .idle)
    }

    func testNothingPendingStaysIdleNoMatterHowMuchTimePasses() {
        let progress = LibraryDownloadProgress().recording(pending: 0, now: t0)
        let muchLater = t0.addingTimeInterval(86_400)
        XCTAssertEqual(progress.state(now: muchLater), .idle)
    }

    func testNewlyObservedPendingCountIsDownloading() {
        let progress = LibraryDownloadProgress().recording(pending: 7563, now: t0)
        XCTAssertEqual(progress.state(now: t0), .downloading(pending: 7563))
    }

    func testUnchangedPendingCountBecomesStalledOnceThresholdPasses() {
        let progress = LibraryDownloadProgress()
            .recording(pending: 7563, now: t0)
            .recording(pending: 7563, now: t0.addingTimeInterval(30))

        let justBefore = t0.addingTimeInterval(LibraryDownloadProgress.stallThreshold - 1)
        XCTAssertEqual(progress.state(now: justBefore), .downloading(pending: 7563))

        let atThreshold = t0.addingTimeInterval(LibraryDownloadProgress.stallThreshold)
        XCTAssertEqual(progress.state(now: atThreshold), .stalled(pending: 7563, since: t0))
    }

    /// Today's failure mode: the count froze for 40 minutes while the UI still
    /// implied work was happening. Re-recording the SAME count must not look
    /// like progress, however many times a reconcile reports it.
    func testRepeatedlyReportingTheSameCountDoesNotResetTheStallClock() {
        var progress = LibraryDownloadProgress().recording(pending: 7563, now: t0)
        for tick in stride(from: 30.0, through: 600.0, by: 30.0) {
            progress = progress.recording(pending: 7563, now: t0.addingTimeInterval(tick))
        }
        XCTAssertEqual(
            progress.state(now: t0.addingTimeInterval(600)),
            .stalled(pending: 7563, since: t0)
        )
    }

    func testPendingCountDroppingCountsAsProgressAndClearsStalled() {
        let stalled = LibraryDownloadProgress().recording(pending: 7563, now: t0)
        let later = t0.addingTimeInterval(LibraryDownloadProgress.stallThreshold + 60)
        XCTAssertEqual(stalled.state(now: later), .stalled(pending: 7563, since: t0))

        let moved = stalled.recording(pending: 4513, now: later)
        XCTAssertEqual(moved.state(now: later), .downloading(pending: 4513))
    }

    /// A count that RISES is still progress — a sync from another device adds
    /// sidecars. Treating only decreases as movement would wrongly report a
    /// busy container as stalled.
    func testPendingCountRisingAlsoCountsAsProgress() {
        let progress = LibraryDownloadProgress().recording(pending: 100, now: t0)
        let later = t0.addingTimeInterval(LibraryDownloadProgress.stallThreshold + 60)
        let grown = progress.recording(pending: 250, now: later)
        XCTAssertEqual(grown.state(now: later), .downloading(pending: 250))
    }

    func testFinishingDownloadsReturnsToIdle() {
        let progress = LibraryDownloadProgress()
            .recording(pending: 7563, now: t0)
            .recording(pending: 0, now: t0.addingTimeInterval(120))
        XCTAssertEqual(progress.state(now: t0.addingTimeInterval(999)), .idle)
    }
}

/// The banner wording is a pure function of (state, indexed count, clock), so
/// it's tested here rather than through a view. Locale is injected: the
/// thousands separator otherwise makes these assertions machine-dependent.
final class LibraryDownloadStatusTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let en = Locale(identifier: "en_US")

    func testIdleHasNothingToSay() {
        let state = LibraryDownloadProgress.State.idle
        XCTAssertNil(state.statusText(indexedItems: 8049, now: t0, locale: en))
    }

    /// The total is what makes it legible: "1,947" alone reads as a small
    /// library, "1,947 of 8,049" reads as one that is still arriving.
    func testDownloadingNamesBothThePendingCountAndTheTotal() {
        let state = LibraryDownloadProgress.State.downloading(pending: 6102)
        XCTAssertEqual(
            state.statusText(indexedItems: 1947, now: t0, locale: en),
            "6,102 of 8,049 items still downloading from iCloud"
        )
    }

    func testStalledSaysHowLongItHasBeenStuck() {
        let since = t0.addingTimeInterval(-300)
        let state = LibraryDownloadProgress.State.stalled(pending: 6102, since: since)
        XCTAssertEqual(
            state.statusText(indexedItems: 1947, now: t0, locale: en),
            "6,102 of 8,049 items waiting on iCloud — no progress for 5 min"
        )
    }

    func testStalledDurationRoundsDownToWholeMinutes() {
        let since = t0.addingTimeInterval(-149)   // 2 min 29 s
        let state = LibraryDownloadProgress.State.stalled(pending: 5, since: since)
        let text = state.statusText(indexedItems: 0, now: t0, locale: en)
        XCTAssertEqual(text, "5 of 5 items waiting on iCloud — no progress for 2 min")
    }

    /// The noun agrees with the TOTAL, not the pending count — "1 of 11 items"
    /// is plural, "1 of 1 item" is not.
    func testNounAgreesWithTheTotalRatherThanThePendingCount() {
        let manyTotal = LibraryDownloadProgress.State.downloading(pending: 1)
        XCTAssertEqual(
            manyTotal.statusText(indexedItems: 10, now: t0, locale: en),
            "1 of 11 items still downloading from iCloud"
        )

        let loneTotal = LibraryDownloadProgress.State.downloading(pending: 1)
        XCTAssertEqual(
            loneTotal.statusText(indexedItems: 0, now: t0, locale: en),
            "1 of 1 item still downloading from iCloud"
        )
    }
}

/// "Rebuild Index" must always report something — pressing it twice with no
/// visible change is the bug this replaces. Unlike the banner, a rebuild that
/// found nothing missing still has to say that it ran.
final class LibraryRebuildSummaryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let en = Locale(identifier: "en_US")

    func testCompleteRebuildReportsWhatItIndexed() {
        let state = LibraryDownloadProgress.State.idle
        XCTAssertEqual(
            state.rebuildSummary(indexedItems: 8049, now: t0, locale: en),
            "Indexed 8,049 items."
        )
    }

    func testEmptyLibraryStillReportsARun() {
        let state = LibraryDownloadProgress.State.idle
        XCTAssertEqual(
            state.rebuildSummary(indexedItems: 0, now: t0, locale: en),
            "Indexed 0 items."
        )
    }

    /// The case that would have explained today: the rebuild genuinely ran and
    /// correctly changed nothing, because the files weren't there to index.
    func testRebuildBlockedByUndownloadedFilesSaysSoRatherThanClaimingSuccess() {
        let state = LibraryDownloadProgress.State.downloading(pending: 7563)
        XCTAssertEqual(
            state.rebuildSummary(indexedItems: 486, now: t0, locale: en),
            "7,563 of 8,049 items still downloading from iCloud"
        )
    }

    func testStalledRebuildSurfacesTheStall() {
        let state = LibraryDownloadProgress.State.stalled(
            pending: 7563, since: t0.addingTimeInterval(-2400))
        XCTAssertEqual(
            state.rebuildSummary(indexedItems: 486, now: t0, locale: en),
            "7,563 of 8,049 items waiting on iCloud — no progress for 40 min"
        )
    }
}

