import Foundation

/// Coalesces a burst of `schedule()` calls into a single delayed action.
///
/// `NSMetadataQuery` fires `NSMetadataQueryDidUpdate` once per file change.
/// During a publish-date backfill that rewrites every sidecar, the unsmoothed
/// handler ran `reconcileNow()` — a full directory walk + re-ingest of every
/// item — *per file change*, producing O(K × N) work for K backfilled items in
/// a library of N. This scheduler delays the underlying reconcile by `debounce`
/// and cancels the pending run if another `schedule()` arrives in the window,
/// reducing that to a single reconcile per quiet period.
///
/// `@MainActor`-bound because the only caller (`LibraryStore`) is main-actor
/// isolated and the wrapped action drives `@Published` state.
@MainActor
final class ReconcileScheduler {
    private let action: @MainActor () async -> Void
    private let debounce: Duration
    private var pending: Task<Void, Never>?

    init(debounce: Duration, action: @escaping @MainActor () async -> Void) {
        self.debounce = debounce
        self.action = action
    }

    /// Schedule the action to run after the debounce window. Subsequent calls
    /// inside the window cancel the pending run and restart the timer.
    func schedule() {
        pending?.cancel()
        let delay = debounce
        let work = action
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await work()
            await MainActor.run { self?.pending = nil }
        }
    }

    /// Cancel any pending action. Safe to call when nothing is pending.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
