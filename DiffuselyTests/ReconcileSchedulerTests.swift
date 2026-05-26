import Testing
import Foundation
@testable import Diffusely

/// Tests for `ReconcileScheduler` — the debouncer that collapses rapid-fire
/// `NSMetadataQueryDidUpdate` notifications during a backfill into a single
/// `reconcileNow()` call instead of one full directory walk per file write.
@Suite struct ReconcileSchedulerTests {

    @MainActor
    @Test func coalescesRapidScheduleCallsIntoSingleAction() async throws {
        let counter = CallCounter()
        // Larger debounce than the wait between schedule() calls — even under
        // parallel test load each iteration finishes in microseconds, well
        // inside the 100ms window, so all 10 collapse to a single fire.
        let scheduler = ReconcileScheduler(debounce: .milliseconds(100)) {
            await counter.increment()
        }

        for _ in 0..<10 { scheduler.schedule() }

        try await Task.sleep(for: .milliseconds(300))

        let count = await counter.value
        #expect(count == 1, "Expected 1 coalesced call, got \(count)")
    }

    @MainActor
    @Test func separateBurstsAfterWindowProduceMultipleActions() async throws {
        let counter = CallCounter()
        let scheduler = ReconcileScheduler(debounce: .milliseconds(50)) {
            await counter.increment()
        }

        scheduler.schedule()
        try await Task.sleep(for: .milliseconds(200))   // > debounce + slack
        scheduler.schedule()
        try await Task.sleep(for: .milliseconds(200))

        let count = await counter.value
        #expect(count == 2, "Two non-overlapping bursts should produce 2 calls, got \(count)")
    }

    @MainActor
    @Test func cancelDropsPendingAction() async throws {
        let counter = CallCounter()
        let scheduler = ReconcileScheduler(debounce: .milliseconds(50)) {
            await counter.increment()
        }

        scheduler.schedule()
        scheduler.cancel()

        try await Task.sleep(for: .milliseconds(200))

        let count = await counter.value
        #expect(count == 0)
    }
}

private actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
