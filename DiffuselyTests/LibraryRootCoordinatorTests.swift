import XCTest
@testable import Diffusely

@MainActor
final class LibraryRootCoordinatorTests: XCTestCase {
    /// Records the sequence the coordinator drives, so ordering is asserted
    /// directly rather than inferred.
    private final class Recorder {
        var steps: [String] = []
    }

    /// One-shot async gate used to make interleaving deterministic in the
    /// concurrency test: `wait()` suspends until `open()` is called (or
    /// returns immediately if `open()` already ran).
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

    private func makeCoordinator(
        recorder: Recorder,
        validate: @escaping (URL) async -> LibraryRootError? = { _ in nil },
        rebuildFails: Bool = false,
        rebuildOutcome: LibraryRootCoordinator.RebuildOutcome = .scanned
    ) -> LibraryRootCoordinator {
        let deps = LibraryRootCoordinator.Dependencies(
            validate: validate,
            beginSwitch: { recorder.steps.append("beginSwitch") },
            quiesce: { recorder.steps.append("quiesce") },
            applyRoot: { _ in recorder.steps.append("applyRoot") },
            rebootstrapVault: { recorder.steps.append("rebootstrapVault") },
            wipeIndex: { recorder.steps.append("wipeIndex") },
            rebuildIndex: {
                recorder.steps.append("rebuildIndex")
                if rebuildFails { throw LibraryRootError.unavailable(URL(fileURLWithPath: "/tmp/gone")) }
                return rebuildOutcome
            },
            restartStore: { recorder.steps.append("restartStore") },
            endSwitch: { recorder.steps.append("endSwitch") },
            reportUnavailable: { _ in recorder.steps.append("reportUnavailable") }
        )
        return LibraryRootCoordinator(dependencies: deps)
    }

    func testHappyPathRunsEveryStepInOrder() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        XCTAssertNil(error)
        // `endSwitch` clears the gate BEFORE `restartStore` runs: `restartStore`'s
        // reconcile checks the gate, and it must already read as un-blocked for
        // that reconcile to actually do anything for the new root.
        XCTAssertEqual(recorder.steps, [
            "beginSwitch", "quiesce", "applyRoot", "rebootstrapVault",
            "wipeIndex", "rebuildIndex", "endSwitch", "restartStore"
        ])
    }

    func testQuiesceHappensBeforeTheRootIsApplied() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        _ = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        let quiesce = recorder.steps.firstIndex(of: "quiesce")!
        let apply = recorder.steps.firstIndex(of: "applyRoot")!
        XCTAssertLessThan(quiesce, apply, "triggers must stop before the root moves")
    }

    func testIndexIsWipedBeforeItIsRebuilt() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        _ = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        let wipe = recorder.steps.firstIndex(of: "wipeIndex")!
        let rebuild = recorder.steps.firstIndex(of: "rebuildIndex")!
        XCTAssertLessThan(wipe, rebuild)
    }

    func testValidationFailureChangesNothing() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, validate: { _ in .encryptedLibrary })
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/sealed")))

        XCTAssertEqual(error, .encryptedLibrary)
        XCTAssertEqual(recorder.steps, [], "a rejected folder must not start a switch")
    }

    func testSwitchingToICloudSkipsValidation() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, validate: { _ in .notADirectory })
        let error = await coordinator.switchTo(.iCloud)

        XCTAssertNil(error)
        XCTAssertTrue(recorder.steps.contains("applyRoot"))
    }

    /// A failure past the flip must NOT quietly restore the old root — that
    /// pairs a half-built index with a root the user didn't choose.
    func testFailureAfterTheFlipReportsUnavailableAndDoesNotRevert() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, rebuildFails: true)
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        XCTAssertNotNil(error)
        XCTAssertTrue(recorder.steps.contains("reportUnavailable"))
        XCTAssertFalse(recorder.steps.contains("endSwitch"),
                       "a failed switch stays blocked rather than releasing the gate")
    }

    /// FINDING 1. Switching BACK to an encrypted iCloud Library rebuilds
    /// nothing, and that is correct, not a failure.
    ///
    /// `rebootstrapVault` builds a FRESH `LibraryVault` with no cached DEK, so
    /// it reports `.locked` the instant `vault.json` exists — only the unlock UI
    /// ever calls `unlockWithBiometrics()`. Reconcile's locked guard then
    /// declines to scan, protecting the index exactly as designed, and
    /// `live(store:)` reports that as `.lockedVault`.
    ///
    /// Before the fix the coordinator turned that correct outcome into a failed
    /// switch: the index was already wiped, `reportUnavailable` fired, and the
    /// gate blocked with "Library not found at /" whose only exits were Locate…
    /// and a "Switch Back to iCloud" that reproduced the identical failure —
    /// with the unlock UI unreachable behind the block. The spec's step 5 says
    /// the opposite: "Back to iCloud → whatever `vault.json` says, so a locked
    /// vault correctly shows the unlock gate again."
    func testLockedVaultRebuildIsASuccessfulSwitchNotAFailure() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, rebuildOutcome: .lockedVault)
        let error = await coordinator.switchTo(.iCloud)

        XCTAssertNil(error, "a locked encrypted vault is the EXPECTED result of switching back to iCloud")
        XCTAssertTrue(recorder.steps.contains("endSwitch"),
                      "the gate must be released so it can settle on .locked and show the unlock UI")
        XCTAssertFalse(recorder.steps.contains("reportUnavailable"),
                       "a locked vault must not block the Library behind an unreachable recovery gate")
        XCTAssertEqual(recorder.steps, [
            "beginSwitch", "quiesce", "applyRoot", "rebootstrapVault",
            "wipeIndex", "rebuildIndex", "endSwitch", "restartStore"
        ])
    }

    /// The other half of Finding 1: the guard's ORIGINAL protection is intact.
    /// A rebuild that scanned nothing for any reason OTHER than a locked vault
    /// still leaves a wiped index, so it must still fail into the blocked state
    /// rather than being reported as a completed switch.
    func testRebuildThatScannedNothingForAnyOtherReasonStillBlocks() async {
        let recorder = Recorder()
        let gone = URL(fileURLWithPath: "/Volumes/Gone")
        let coordinator = makeCoordinator(recorder: recorder, rebuildOutcome: .failed(gone))
        let error = await coordinator.switchTo(.custom(gone))

        XCTAssertEqual(error, .unavailable(gone))
        XCTAssertTrue(recorder.steps.contains("reportUnavailable"))
        XCTAssertFalse(recorder.steps.contains("endSwitch"),
                       "a wiped index over an unreadable root must stay blocked")
    }

    /// FINDING 3. A failed switch must never name a path the user did not
    /// choose. A switch back to iCloud has no chosen folder at all, so the
    /// reported URL is `nil` and the UI words itself for that — rather than the
    /// old `URL(fileURLWithPath: "/")`, which produced "Library not found at /."
    /// and then invited the user to Locate… it.
    func testFailedSwitchToICloudNamesNoBogusPath() async {
        var reported: [URL?] = []
        let deps = LibraryRootCoordinator.Dependencies(
            validate: { _ in nil },
            beginSwitch: { },
            quiesce: { },
            applyRoot: { _ in },
            rebootstrapVault: { },
            wipeIndex: { },
            rebuildIndex: { throw CocoaError(.fileReadUnknown) },
            restartStore: { },
            endSwitch: { },
            reportUnavailable: { reported.append($0) }
        )
        let coordinator = LibraryRootCoordinator(dependencies: deps)

        let error = await coordinator.switchTo(.iCloud)

        XCTAssertEqual(reported.count, 1)
        XCTAssertNil(reported.first ?? URL(fileURLWithPath: "/"),
                     "no user-chosen folder is implicated, so none may be named")
        XCTAssertEqual(error, .switchFailed)
        XCTAssertFalse(error!.message.contains("/"),
                       "the message must not name a path at all")
    }

    /// A failed switch to a CUSTOM folder still names that folder — the useful
    /// half of the old behaviour, kept.
    func testFailedSwitchToACustomFolderNamesThatFolder() async {
        var reported: [URL?] = []
        let target = URL(fileURLWithPath: "/Volumes/Media/Diffusely")
        let deps = LibraryRootCoordinator.Dependencies(
            validate: { _ in nil },
            beginSwitch: { },
            quiesce: { },
            applyRoot: { _ in },
            rebootstrapVault: { },
            wipeIndex: { },
            rebuildIndex: { throw CocoaError(.fileReadUnknown) },
            restartStore: { },
            endSwitch: { },
            reportUnavailable: { reported.append($0) }
        )
        let coordinator = LibraryRootCoordinator(dependencies: deps)

        _ = await coordinator.switchTo(.custom(target))

        XCTAssertEqual(reported, [target])
    }

    /// Two concurrent `switchTo` calls must not interleave their sequences:
    /// the second call, arriving while the first is still mid-flight (parked
    /// in `quiesce`), must be rejected without running any step of its own.
    func testConcurrentSwitchIsRejectedWhileOneIsInFlight() async {
        let recorder = Recorder()
        let quiesceStarted = Signal()
        let canProceed = Signal()

        let deps = LibraryRootCoordinator.Dependencies(
            validate: { _ in nil },
            beginSwitch: { recorder.steps.append("beginSwitch") },
            quiesce: {
                recorder.steps.append("quiesce")
                await quiesceStarted.open()
                await canProceed.wait()
            },
            applyRoot: { _ in recorder.steps.append("applyRoot") },
            rebootstrapVault: { recorder.steps.append("rebootstrapVault") },
            wipeIndex: { recorder.steps.append("wipeIndex") },
            rebuildIndex: { recorder.steps.append("rebuildIndex"); return .scanned },
            restartStore: { recorder.steps.append("restartStore") },
            endSwitch: { recorder.steps.append("endSwitch") },
            reportUnavailable: { _ in recorder.steps.append("reportUnavailable") }
        )
        let coordinator = LibraryRootCoordinator(dependencies: deps)

        let firstTask = Task {
            await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))
        }
        // Wait until the first call is parked in `quiesce` (i.e. definitely
        // past `isSwitching = true`) before firing the second call.
        await quiesceStarted.wait()

        let secondError = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/other")))
        XCTAssertNotNil(secondError, "a switch already in flight must reject a second one")

        await canProceed.open()
        let firstError = await firstTask.value
        XCTAssertNil(firstError)

        XCTAssertEqual(recorder.steps.filter { $0 == "beginSwitch" }.count, 1,
                       "the sequence must run exactly once, not interleaved")
        XCTAssertEqual(recorder.steps, [
            "beginSwitch", "quiesce", "applyRoot", "rebootstrapVault",
            "wipeIndex", "rebuildIndex", "endSwitch", "restartStore"
        ], "the rejected second call must not have appended any step of its own")
    }

    /// The re-entrancy guard must be set BEFORE `validate` is awaited, not
    /// merely before `quiesce` (already covered above). `validate` genuinely
    /// suspends in production — `live(store:)`'s validate awaits an
    /// actor-isolated lookup on `LibraryContainer` — so a second `switchTo`
    /// arriving while the first is still parked inside `validate` must still
    /// be rejected. Before the fix, `isSwitching` was set only AFTER
    /// validation, so both calls could read it as `false` and both would run.
    func testConcurrentSwitchIsRejectedWhileValidateIsInFlight() async {
        let recorder = Recorder()
        let validateStarted = Signal()
        let canProceed = Signal()

        let deps = LibraryRootCoordinator.Dependencies(
            validate: { _ in
                await validateStarted.open()
                await canProceed.wait()
                return nil
            },
            beginSwitch: { recorder.steps.append("beginSwitch") },
            quiesce: { recorder.steps.append("quiesce") },
            applyRoot: { _ in recorder.steps.append("applyRoot") },
            rebootstrapVault: { recorder.steps.append("rebootstrapVault") },
            wipeIndex: { recorder.steps.append("wipeIndex") },
            rebuildIndex: { recorder.steps.append("rebuildIndex"); return .scanned },
            restartStore: { recorder.steps.append("restartStore") },
            endSwitch: { recorder.steps.append("endSwitch") },
            reportUnavailable: { _ in recorder.steps.append("reportUnavailable") }
        )
        let coordinator = LibraryRootCoordinator(dependencies: deps)

        let firstTask = Task {
            await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))
        }
        // Wait until the first call is parked INSIDE `validate` — i.e. before
        // any step has been recorded, and (if the guard were wrongly placed
        // after validation) before `isSwitching` would even be set yet.
        await validateStarted.wait()

        let secondTask = Task {
            await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/other")))
        }
        // The first call cannot progress past `validate` until `canProceed`
        // is opened below, so yielding here gives the second call's guard
        // check a deterministic chance to run while the first is still
        // genuinely suspended — not a timing guess.
        await Task.yield()

        await canProceed.open()

        let firstError = await firstTask.value
        let secondError = await secondTask.value

        XCTAssertNil(firstError)
        XCTAssertNotNil(secondError,
                        "a switch already in flight — even mid-validate — must reject a second one")

        XCTAssertEqual(recorder.steps, [
            "beginSwitch", "quiesce", "applyRoot", "rebootstrapVault",
            "wipeIndex", "rebuildIndex", "endSwitch", "restartStore"
        ], "the sequence must run exactly once — a second call arriving while the first is still inside validate must not interleave its own steps")
    }
}
