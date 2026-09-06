import Foundation
import SwiftUI

/// Rate-limits progress ticks. The engine reports every item; at 6,500 items a
/// main-actor hop each would be needless churn, so ticks are coalesced to one
/// per `interval` — with the final tick always allowed through so the bar
/// actually reaches 100%.
struct ExportProgressCoalescer {
    private let interval: TimeInterval
    private var lastEmit: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func shouldEmit(at now: Date, isFinal: Bool) -> Bool {
        if isFinal {
            lastEmit = now
            return true
        }
        if let lastEmit, now.timeIntervalSince(lastEmit) < interval {
            return false
        }
        lastEmit = now
        return true
    }
}

/// Drives one Library export: resolves the vault, validates the destination,
/// builds the plan, and runs `LibraryExporter` on a dedicated serial queue.
///
/// Follows `LibraryEncryptionCoordinator` (published `Phase`, dedicated
/// `ioQueue`) and `SortAssistantService` (`runTask` + `cancel()`). The vault is
/// reached through an injected closure, matching the `resolveVaultContext`
/// seam used by `SortAssistantScanner` and `LibraryAlbumService`, so tests
/// never touch the shared singleton.
@MainActor
final class LibraryExportService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case confirming(LibraryExportPlan)
        /// `total` is nil until the engine's container walk reports the real
        /// denominator. Deliberately NOT seeded from the plan's index
        /// estimate: the two routinely disagree (the index is a disposable
        /// cache, the container is truth), and seeding "3" only to have the
        /// first engine tick replace it with "1 of 6,220" reads as a glitch.
        /// The sheet shows an indeterminate bar for that first moment instead.
        case exporting(done: Int, total: Int?)
        case finished(LibraryExportSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Destination chosen in the open panel; retained for `start()` and for
    /// the sheet's "Reveal in Finder".
    private(set) var destination: URL?

    private let resolveContext: () async -> (LibraryVault.State, LibraryFileStore)
    private let sizingRows: () async -> [LibraryExportSizingRow]

    private var store: LibraryFileStore?
    private var runTask: Task<Void, Never>?
    /// Identifies the currently-live run. Bumped at the top of every
    /// `prepare()` call, and captured by value into each run's completion
    /// and progress closures in `start()`. Every write to `phase` from
    /// those closures compares its captured token against the current one
    /// first — see the comment in `prepare()` for why this is needed on top
    /// of the cancel-and-await join below.
    private var runToken = 0
    /// Set on the main actor, read from the export queue and from inside the
    /// materializer's wait loop, so it needs real cross-thread safety — a
    /// main-actor `Bool` read via `MainActor.assumeIsolated` would trap when
    /// the export thread calls it.
    private var cancelFlag = CancelFlag()

    /// Minimal thread-safe latch for cooperative cancellation.
    final class CancelFlag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock(); value = true; lock.unlock()
        }
    }

    /// Dedicated serial queue for the export loop's blocking work: coordinated
    /// reads, iCloud materialization waits, AES-GCM opens, destination writes.
    /// Mirrors `LibraryEncryptionCoordinator.ioQueue`. Serial because progress
    /// ordering and the write cursor's one-at-a-time contract both depend on it.
    private static let exportQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.export",
        qos: .userInitiated
    )

    init(resolveContext: @escaping () async -> (LibraryVault.State, LibraryFileStore),
         sizingRows: @escaping () async -> [LibraryExportSizingRow]) {
        self.resolveContext = resolveContext
        self.sizingRows = sizingRows
    }

    /// Production wiring: the shared vault plus the live index.
    static func live(indexService: LibraryIndexService) -> LibraryExportService {
        LibraryExportService(
            resolveContext: { await LibraryVaultProvider.shared.reconcileContext() },
            sizingRows: { await indexService.exportSizingRows() })
    }

    // MARK: Pre-flight

    func prepare(destination: URL) async {
        // Bump the token before anything else. This invalidates every
        // `phase` write still owned by whatever run is currently in flight —
        // including the one this very call is about to join below. Without
        // this, that run's own completion (and any late progress tick) still
        // executes its `self.phase = ...` line while this method `await`s
        // it, which publishes synchronously to every observer of
        // `@Published phase` (a SwiftUI view, a Combine sink) before this
        // call gets a chance to move `phase` on to the new sequence — a
        // superseded run's stale value would briefly appear as real. The
        // token guarantees the old run never touches `phase` again, full
        // stop, rather than merely making its clobber non-permanent.
        runToken += 1
        let token = runToken

        // A run started by an earlier `prepare()`/`start()` cycle may still
        // be executing on `exportQueue` — its `Task` lives independently of
        // this call. If one is in flight, ask it to stop and wait for it to
        // actually finish before this method starts driving `phase` again.
        // This still matters even with the token guard above: without the
        // join, the old run would keep touching `store`/`destination` (and
        // holding the `beginActivity` assertion) concurrently with the new
        // run this call is about to set up. When nothing is in flight —
        // `runTask` is `nil`, or already completed and nilled out below —
        // `await runTask.value` returns immediately, so the normal
        // single-flight path pays nothing extra.
        if let runTask {
            cancelFlag.set()
            await runTask.value
        }

        // A fresh flag for the pre-flight itself. `prepare()` is no longer
        // trivially fast — it lists the destination (~13,000 names when
        // re-running into an existing archive) and probes the destination
        // volume, either of which can take seconds on a sleeping external
        // drive or an SMB mount — so dismissing the sheet mid-pre-flight must
        // actually stop it publishing phases, not merely be ignored.
        // `start()` installs its own flag for the run proper.
        cancelFlag = CancelFlag()
        let flag = cancelFlag

        phase = .preparing
        self.destination = destination

        // One resolve, up front: state and crypto must come from the same
        // snapshot or a lock landing between two reads could hand us a
        // passthrough store over an encrypted container.
        let (state, store) = await resolveContext()
        guard runToken == token, !flag.isSet else { return }
        guard state != .locked else {
            return fail(.vaultLocked)
        }
        self.store = store

        // Every step below touches the filesystem — `fileExists`,
        // `isWritableFile`, `resolvingSymlinksInPath`, a full
        // `contentsOfDirectory` over the destination, a half-encrypted-store
        // scan, a volume-capacity probe. None of it may run on the main actor
        // (see this repo's `metadata-query-must-run-off-main` and
        // `library-reload-main-thread-fetches` bugs), and none of it may run
        // on the cooperative pool either, since it all blocks — so it goes to
        // the same `exportQueue` the run itself uses, reached by the
        // `withCheckedContinuation` bridge `runExport` already establishes.
        let itemsDirectory = store.itemsDirectory
        if let error = await Self.onExportQueue({
            LibraryExportDestination.validateForExport(
                destination: destination, itemsDirectory: itemsDirectory)
        }) {
            guard runToken == token, !flag.isSet else { return }
            return fail(error)
        }
        guard runToken == token, !flag.isSet else { return }

        // Independent of the UI's `libraryGate == .browsable` gate: a
        // `setupIncomplete` store is unlocked (so the `.locked` guard above
        // passes) but half-encrypted, and reports `isEncrypted == true`, so
        // the engine's enumeration filters to `*.m` and silently omits every
        // leftover plaintext `<id>.json` sidecar. That is a short export
        // reported as a complete one, which is precisely what this feature
        // must never do — so the service refuses it itself rather than
        // trusting the caller to have gated it.
        if state == .unlocked, let crypto = store.crypto {
            let pending = await Self.onExportQueue {
                LibraryEncryptionMigrator(itemsDirectory: itemsDirectory, crypto: crypto)
                    .pendingItemsAndAuxCount()
            }
            guard runToken == token, !flag.isSet else { return }
            guard pending == 0 else { return fail(.setupIncomplete) }
        }

        let rows = await sizingRows()
        guard runToken == token, !flag.isSet else { return }

        let plan = await Self.onExportQueue {
            LibraryExportPlanner.plan(
                destination: destination,
                rows: rows,
                availableBytes: LibraryExportPlanner.availableCapacity(at: destination))
        }
        guard runToken == token, !flag.isSet else { return }

        guard plan.fitsOnDisk else {
            // "Couldn't measure" and "measured, and it's full" are different
            // refusals: reporting an unreadable volume as `available: 0` told
            // users of exFAT/SMB destinations that a 4 TB drive was full.
            guard let available = plan.availableBytes else {
                return fail(.capacityUnknown(needed: plan.bytesToWrite,
                                             path: destination.path))
            }
            return fail(.insufficientSpace(needed: plan.bytesToWrite,
                                           available: available))
        }
        phase = .confirming(plan)
    }

    // MARK: Run

    func start() {
        guard case .confirming(let plan) = phase,
              let store, let destination else { return }

        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let token = runToken
        // Indeterminate until the engine's walk reports the real total — see
        // `Phase.exporting`. The plan's figure is an index estimate and the
        // engine's is the container's truth; showing the estimate first only
        // to swap it out looks like a bug.
        phase = .exporting(done: 0, total: nil)

        runTask = Task { [weak self] in
            let summary = await Self.runExport(
                store: store,
                destination: destination,
                indexedItemCount: plan.indexedItems,
                shouldCancel: { flag.isSet },
                onProgress: { done, total in
                    Task { @MainActor [weak self] in
                        // `runToken` check first: a superseded run's late
                        // tick must not write `phase` even once, regardless
                        // of what `phase` currently holds.
                        guard let self, self.runToken == token,
                              case .exporting = self.phase else { return }
                        self.phase = .exporting(done: done, total: total)
                    }
                })
            guard let self else { return }
            // Only the still-current run gets to publish its result. A
            // superseded run (its token invalidated by a later `prepare()`
            // while this `Task` was still in flight) reaches here too —
            // `prepare()`'s cancel-and-await join is what waits for it — but
            // must not write `phase` at all, not even transiently.
            if self.runToken == token {
                self.phase = .finished(summary)
            }
            // Marks this run as no-longer-in-flight so a subsequent
            // `prepare()` sees `runTask == nil` and skips the cancel-and-await
            // above instead of re-joining an already-finished task.
            self.runTask = nil
        }
    }

    func cancel() {
        cancelFlag.set()
    }

    // MARK: Queue bridge

    /// Runs the engine on `exportQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread. Mirrors
    /// `LibraryEncryptionCoordinator.runOnIOQueue`.
    private static func runExport(
        store: LibraryFileStore,
        destination: URL,
        indexedItemCount: Int,
        shouldCancel: @escaping () -> Bool,
        onProgress: @escaping (Int, Int) -> Void
    ) async -> LibraryExportSummary {
        await withCheckedContinuation { continuation in
            exportQueue.async {
                // An export can run for hours. Keep the Mac from idle-sleeping
                // through it; closing the lid still suspends normally.
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated],
                    reason: "Exporting the Diffusely library")
                defer { ProcessInfo.processInfo.endActivity(activity) }

                var coalescer = ExportProgressCoalescer(interval: 0.1)
                let exporter = LibraryExporter(
                    store: store,
                    destination: destination,
                    indexedItemCount: indexedItemCount,
                    shouldCancel: shouldCancel)
                let summary = exporter.run { done, total in
                    if coalescer.shouldEmit(at: Date(), isFinal: done == total) {
                        onProgress(done, total)
                    }
                }
                continuation.resume(returning: summary)
            }
        }
    }

    /// Runs one piece of blocking pre-flight work on `exportQueue` and
    /// suspends the caller until it finishes, without occupying a cooperative
    /// thread — the same bridge `runExport` uses, for the same reason.
    private static func onExportQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            exportQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Helpers

    private func fail(_ error: LibraryExportError) {
        phase = .failed(error.errorDescription ?? "Export failed.")
    }
}
