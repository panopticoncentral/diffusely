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
        let scheduler = ReconcileScheduler(debounce: .milliseconds(30)) {
            await counter.increment()
        }

        // Fire many schedule() in tight succession.
        for _ in 0..<10 { scheduler.schedule() }

        // Wait past the debounce window so the coalesced action fires.
        try await Task.sleep(for: .milliseconds(120))

        let count = await counter.value
        #expect(count == 1, "Expected 1 coalesced call, got \(count)")
    }

    @MainActor
    @Test func separateBurstsAfterWindowProduceMultipleActions() async throws {
        let counter = CallCounter()
        let scheduler = ReconcileScheduler(debounce: .milliseconds(20)) {
            await counter.increment()
        }

        scheduler.schedule()
        try await Task.sleep(for: .milliseconds(80))
        scheduler.schedule()
        try await Task.sleep(for: .milliseconds(80))

        let count = await counter.value
        #expect(count == 2, "Two non-overlapping bursts should produce 2 calls, got \(count)")
    }

    @MainActor
    @Test func cancelDropsPendingAction() async throws {
        let counter = CallCounter()
        let scheduler = ReconcileScheduler(debounce: .milliseconds(30)) {
            await counter.increment()
        }

        scheduler.schedule()
        scheduler.cancel()

        try await Task.sleep(for: .milliseconds(80))

        let count = await counter.value
        #expect(count == 0)
    }
}

private actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
