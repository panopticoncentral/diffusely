#if os(macOS)
import XCTest
@testable import Diffusely

/// FINDING 2. The coordinator's `isSwitching` re-entrancy latch is per-INSTANCE,
/// so it only means anything if every switch runs through the SAME coordinator.
/// `LibraryLocationSwitcher.apply` used to build a fresh
/// `LibraryRootCoordinator.live(store:)` on every call, which made the latch
/// unobservable in production: the coordinator tests passed only because they
/// deliberately reused one instance.
///
/// These drive the production entry point — `LibraryLocationSwitcher.apply` —
/// through its coordinator-construction seam, so they fail if the shared
/// instance is ever removed.
@MainActor
final class LibraryLocationSwitcherTests: XCTestCase {
    private final class Recorder {
        var steps: [String] = []
    }

    /// One-shot async gate, so the interleaving is deterministic rather than a
    /// timing guess.
    private actor Signal {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            guard !isOpen else { return }
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    override func setUp() async throws {
        LibraryLocationSwitcher.resetSharedCoordinatorForTesting()
    }

    override func tearDown() async throws {
        LibraryLocationSwitcher.resetSharedCoordinatorForTesting()
    }

    private func makeCoordinator(
        recorder: Recorder,
        quiesceStarted: Signal? = nil,
        canProceed: Signal? = nil
    ) -> LibraryRootCoordinator {
        LibraryRootCoordinator(dependencies: LibraryRootCoordinator.Dependencies(
            validate: { _ in nil },
            beginSwitch: { recorder.steps.append("beginSwitch") },
            quiesce: {
                recorder.steps.append("quiesce")
                await quiesceStarted?.open()
                await canProceed?.wait()
            },
            applyRoot: { _ in recorder.steps.append("applyRoot") },
            rebootstrapVault: { recorder.steps.append("rebootstrapVault") },
            wipeIndex: { recorder.steps.append("wipeIndex") },
            rebuildIndex: { recorder.steps.append("rebuildIndex"); return .scanned },
            restartStore: { recorder.steps.append("restartStore") },
            endSwitch: { recorder.steps.append("endSwitch") },
            reportUnavailable: { _ in recorder.steps.append("reportUnavailable") }
        ))
    }

    /// The switcher builds its coordinator once and reuses it — which is the
    /// only reason the latch inside it can ever observe anything.
    func testApplyReusesOneCoordinatorAcrossCalls() async {
        let recorder = Recorder()
        var builds = 0
        let coordinator = makeCoordinator(recorder: recorder)

        _ = await LibraryLocationSwitcher.apply(.custom(URL(fileURLWithPath: "/tmp/a"))) {
            builds += 1
            return coordinator
        }
        _ = await LibraryLocationSwitcher.apply(.iCloud) {
            builds += 1
            return coordinator
        }

        XCTAssertEqual(builds, 1, "a per-call coordinator makes the re-entrancy latch dead in production")
    }

    /// Two switches fired through the PRODUCTION entry point, the second
    /// arriving while the first is parked mid-quiesce. The second must be
    /// rejected outright: interleaved, the first switch's `endSwitch()` would
    /// clear the `.switchingRoot` override the second one installed (the
    /// provider matches on the case, not on ownership), un-gating the Library
    /// and restarting the store while the second still had a `wipeIndex` ahead
    /// of it.
    func testTwoSwitchesThroughTheProductionEntryPointCannotInterleave() async {
        let recorder = Recorder()
        let quiesceStarted = Signal()
        let canProceed = Signal()
        let coordinator = makeCoordinator(
            recorder: recorder, quiesceStarted: quiesceStarted, canProceed: canProceed)
        let build: () -> LibraryRootCoordinator = { coordinator }

        let first = Task {
            await LibraryLocationSwitcher.apply(
                .custom(URL(fileURLWithPath: "/tmp/a")), makeCoordinator: build)
        }
        // Park the first call inside `quiesce` — definitely past the latch —
        // before firing the second.
        await quiesceStarted.wait()

        let secondMessage = await LibraryLocationSwitcher.apply(.iCloud, makeCoordinator: build)
        XCTAssertNotNil(secondMessage,
                        "a switch already in flight must reject a second one through apply()")
        XCTAssertEqual(secondMessage, LibraryRootError.switchInProgress.message)

        await canProceed.open()
        let firstMessage = await first.value
        XCTAssertNil(firstMessage)

        XCTAssertEqual(recorder.steps, [
            "beginSwitch", "quiesce", "applyRoot", "rebootstrapVault",
            "wipeIndex", "rebuildIndex", "endSwitch", "restartStore"
        ], "the rejected second call must not have run a single step of its own")
    }
}
#endif
