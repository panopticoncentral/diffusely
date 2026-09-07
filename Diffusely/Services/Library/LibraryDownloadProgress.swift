import Foundation

/// How the Library's pending-download backlog is moving.
///
/// Reconciles only run when the container changes, so a container that has
/// stopped downloading produces no further updates at all — the count simply
/// freezes. That makes "stalled" underivable from the update stream: there is
/// no update to derive it from. So this stores the two facts a scan can supply
/// (the count, and when it last moved) and derives the state at READ time from
/// a caller-supplied clock. The UI re-reads on a timer, so a backlog that has
/// gone quiet reports itself as stalled without anything having to fire.
///
/// Motivating case: an evicted container whose downloads were accepted by the
/// FileProvider but never serviced sat at 7,563 pending for 40 minutes while
/// the app showed a spinner implying work was happening.
struct LibraryDownloadProgress: Equatable {
    /// How long the pending count may sit unchanged before it reads as stalled
    /// rather than merely slow. Long enough to ride out a quiet gap between
    /// batches; short enough that a wedged FileProvider is named while the user
    /// is still looking at it.
    static let stallThreshold: TimeInterval = 120

    enum State: Equatable {
        /// Nothing is waiting: every sidecar is local.
        case idle
        /// Sidecars are outstanding and the backlog is moving.
        case downloading(pending: Int)
        /// Sidecars are outstanding and the count hasn't moved since `since`.
        case stalled(pending: Int, since: Date)
    }

    private(set) var pending: Int
    /// When `pending` last took a different value. `.distantPast` before the
    /// first observation, which is inert: `state` short-circuits on `pending == 0`.
    private(set) var lastChangedAt: Date

    init(pending: Int = 0, lastChangedAt: Date = .distantPast) {
        self.pending = pending
        self.lastChangedAt = lastChangedAt
    }

    /// Folds one reconcile's pending count in. A count that DIFFERS — in either
    /// direction — is progress: a drop means sidecars arrived, and a rise means
    /// another device added some. Only an unchanged count leaves the clock
    /// alone, so repeatedly re-reporting the same backlog can't disguise it as
    /// activity.
    func recording(pending newPending: Int, now: Date) -> LibraryDownloadProgress {
        guard newPending != pending else { return self }
        return LibraryDownloadProgress(pending: newPending, lastChangedAt: now)
    }

    func state(now: Date) -> State {
        guard pending > 0 else { return .idle }
        guard now.timeIntervalSince(lastChangedAt) >= Self.stallThreshold else {
            return .downloading(pending: pending)
        }
        return .stalled(pending: pending, since: lastChangedAt)
    }
}

extension LibraryDownloadProgress.State {
    /// One line describing the backlog, or `nil` when there is nothing to say.
    ///
    /// `indexedItems` is what the Library is currently showing, so the total is
    /// `indexed + pending`. Naming both matters: "6,102" alone reads as a small
    /// library, "6,102 of 8,049" reads as one that is still arriving — which is
    /// the difference between looking like data loss and looking like a
    /// download in progress.
    ///
    /// `locale` is injected so the thousands separator is testable rather than
    /// machine-dependent.
    func statusText(
        indexedItems: Int,
        now: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        let pending: Int
        let tail: String
        switch self {
        case .idle:
            return nil
        case .downloading(let count):
            pending = count
            tail = "still downloading from iCloud"
        case .stalled(let count, let since):
            pending = count
            let minutes = max(0, Int(now.timeIntervalSince(since)) / 60)
            tail = "waiting on iCloud — no progress for \(minutes) min"
        }

        let total = indexedItems + pending
        let noun = total == 1 ? "item" : "items"
        return "\(format(pending, locale: locale)) of \(format(total, locale: locale)) \(noun) \(tail)"
    }

    /// Result line for Settings' "Rebuild Index". Always says something: a
    /// rebuild that found nothing missing still has to confirm it ran, and one
    /// that could not index anything has to say WHY rather than leaving the
    /// user to press the button again.
    func rebuildSummary(
        indexedItems: Int,
        now: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        statusText(indexedItems: indexedItems, now: now, locale: locale)
            ?? "Indexed \(format(indexedItems, locale: locale)) items."
    }

    private func format(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }
}
