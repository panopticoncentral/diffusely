import Foundation
import SwiftData
import Combine

/// Main-actor coordinator that wires the library together: owns the
/// `NSMetadataQuery` (which needs a run loop), drives reconcile on launch and on
/// every iCloud change, surfaces iCloud availability / storage totals / per-item
/// download progress to the UI, and exposes Settings actions.
enum ICloudStatus { case checking, available, unavailable }

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var iCloudStatus: ICloudStatus = .checking
    @Published private(set) var downloadedBytes = 0
    @Published private(set) var itemCount = 0
    @Published private(set) var isReady = false
    /// Session-scoped gate for the publish-date backfill. Lives here (not in
    /// `LibraryView`'s `@State`) so navigating into and out of the Library tab
    /// doesn't restart the backfill — that was making the spinner banner
    /// reappear on every visit even though the work was already complete or
    /// in progress.
    @Published private(set) var didRunDateBackfillThisSession: Bool = false
    @Published private(set) var didRunCheckpointBackfillThisSession: Bool = false
    /// Bumped whenever an album is created/renamed/deleted or membership changes
    /// — by local edits (views call `notifyAlbumsChanged()`) and by reconciles
    /// that ingest album/membership changes synced in from another device.
    /// `LibraryView` observes this to reload, since membership edits don't change
    /// `itemCount`.
    @Published private(set) var albumsVersion: Int = 0

    /// How much of the container is still waiting on iCloud, and whether that
    /// backlog is actually moving. Read by the Library's status banner and the
    /// Settings rebuild result. Only a reconcile that COMPLETED a scan updates
    /// this — see `LibraryIndexService.ReconcileOutcome`.
    @Published private(set) var downloadProgress = LibraryDownloadProgress()

    static let cacheLimitDefaultsKey = "library_cache_limit_bytes"
    static let defaultCacheLimitBytes = 2 * 1024 * 1024 * 1024  // 2 GB

    let indexService: LibraryIndexService
    let albumService: LibraryAlbumService

    private let metadataQuery = NSMetadataQuery()
    /// Dedicated serial queue for the metadata query's gathering/merge work.
    /// Without this, `NSMetadataQuery` runs on the run loop of the thread that
    /// called `start()` (the main thread) — so CloudDocs delivers and merges the
    /// entire result set (6,000+ `.json` sidecars) on the main thread on every
    /// update, hanging the UI. Moving it to a background queue keeps all of that
    /// off the main thread; the only consumer (`handleQueryUpdate`) just schedules
    /// a debounced reconcile and its observer already hops to `.main`.
    private let metadataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.diffusely.library.metadataQuery"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var observers: [NSObjectProtocol] = []
    /// Debounces `NSMetadataQueryDidUpdate` notifications. During the date
    /// backfill, every sidecar rewrite would otherwise re-trigger a full
    /// `reconcileNow()` (a directory walk + per-item re-ingest), turning K
    /// backfill items into O(K × N) work. 750ms is long enough to absorb the
    /// burst from a backfill loop yet short enough that a legitimate iCloud
    /// arrival is still picked up quickly.
    private var reconcileScheduler: ReconcileScheduler?

    /// Change detection for a custom root, where there is no `NSMetadataQuery`.
    /// Exactly one of this and `metadataQuery` is ever active.
    private var folderWatcher: LibraryFolderWatcher?

    /// Keeps `LibrarySaveService.isLibraryBrowsable` — the visibility gate on
    /// the feeds' "already in your library" badge — following the vault gate.
    /// Held here because this is where the save service's other cross-service
    /// wiring already lives (`indexService`, just below), and because the
    /// store outlives every view that renders a badge.
    private var gateObserver: AnyCancellable?

    init(modelContainer: ModelContainer) {
        self.indexService = LibraryIndexService(modelContainer: modelContainer)
        self.albumService = LibraryAlbumService(
            index: indexService,
            itemsDirectory: { try? await LibraryContainer.shared.itemsDirectory() }
        )
        LibrarySaveService.shared.indexService = indexService

        let vaultProvider = LibraryVaultProvider.shared
        let applyGate: (LibraryVaultProvider.LibraryGate) -> Void = { gate in
            LibrarySaveService.shared.setLibraryBrowsable(
                LibrarySaveService.showsSavedBadges(givenLibraryGate: gate)
            )
        }
        applyGate(vaultProvider.libraryGate)
        // `libraryGate` is published from the @MainActor provider, so this
        // delivers on the main thread — same `assumeIsolated` pattern as the
        // metadata-query observers below.
        gateObserver = vaultProvider.$libraryGate.sink { [weak self] gate in
            MainActor.assumeIsolated {
                applyGate(gate)
                // Re-arm the post-unlock catch-up reconcile whenever the gate
                // leaves `.browsable` (the idle auto-lock does this every time
                // the app is backgrounded past its threshold). See
                // `reconcileLatch` for why the latch can't be launch-scoped.
                guard let self else { return }
                self.didReconcileSinceLaunch = Self.reconcileLatch(
                    afterGateChangedTo: gate,
                    currentlyLatched: self.didReconcileSinceLaunch
                )
            }
        }
        self.reconcileScheduler = ReconcileScheduler(debounce: .milliseconds(750)) { [weak self] in
            await self?.reconcileNow()
        }
    }

    var cacheLimitBytes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.cacheLimitDefaultsKey)
            return stored > 0 ? stored : Self.defaultCacheLimitBytes
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.cacheLimitDefaultsKey)
            Task { await enforceCacheLimit() }
        }
    }

    /// Whether a `start()` call must attempt its reconcile. `isReady` alone
    /// cannot answer this, and using it as the sole latch stranded the index on
    /// any device that only READS the library.
    ///
    /// `start()` is called twice in the encrypted-vault flow: once at launch by
    /// `ContentView.startLibrarySubsystem` — deliberately BEFORE any unlock, so
    /// `reconcileNow`'s locked-skip engages instead of scanning a locked
    /// container — and again by `LibraryView`'s `.task(id: libraryGate)` when
    /// the gate reaches `.browsable` after the unlock. The launch call sets
    /// `isReady` regardless of whether its reconcile actually ran, so `guard
    /// !isReady` swallowed that second call: no catch-up reconcile ever ran
    /// after an unlock. The only trigger left was an `NSMetadataQuery` update,
    /// which needs a container change to land while this device is open AND
    /// unlocked — something a device where the user saves items produces
    /// constantly, but a read-only device never does. Those devices' indexes
    /// stayed frozen indefinitely.
    ///
    /// So the latch must be "a reconcile has actually run", not "start() has
    /// been called": whichever call is the first to run while the gate permits
    /// a reconcile has to do it.
    nonisolated static func shouldStartReconcile(
        isReady: Bool,
        didReconcileSinceLaunch: Bool
    ) -> Bool {
        !isReady || !didReconcileSinceLaunch
    }

    /// The reconcile latch's new value after the vault gate changes.
    ///
    /// Scopes the latch to "a reconcile has run since the gate last became
    /// `.browsable`" rather than "since launch". iOS keeps the app's process
    /// alive for days, and the idle auto-lock (`DiffuselyApp`, 300s) re-locks
    /// the vault every time the app sits in the background — so one process
    /// sees many `.browsable` → `.locked` → `.browsable` cycles. A
    /// launch-scoped latch made every unlock after the first a no-op, which
    /// stranded a read-only device: `reconcileNow` drops the `NSMetadataQuery`
    /// changes that land while non-`.browsable` (and the query never
    /// re-delivers them), so those arrivals were lost until the process died.
    /// Clearing the latch on the way out of `.browsable` re-arms the
    /// post-unlock catch-up that recovers them.
    nonisolated static func reconcileLatch(
        afterGateChangedTo gate: LibraryVaultProvider.LibraryGate,
        currentlyLatched: Bool
    ) -> Bool {
        gate == .browsable ? currentlyLatched : false
    }

    /// Set once a reconcile has actually reached the index service — see
    /// `shouldStartReconcile` for why `isReady` can't serve as this latch.
    private var didReconcileSinceLaunch = false

    /// Set true only once a configuration pass has actually installed a
    /// trigger (`configureMetadataQuery()` ran, or `folderWatcher` was
    /// assigned). Left false by a failed resolve, a nil `LibraryFolderWatcher`
    /// init, or a pass that lost the epoch race below — any of those must let
    /// the NEXT `start()` retry rather than latching change detection off for
    /// the rest of the session.
    private var didConfigureChangeDetection = false

    /// The epoch a configuration pass is currently in flight for, or `nil`
    /// when none is. Guards the same "two `start()` calls in quick
    /// succession" race `didConfigureChangeDetection` used to (`isReady`
    /// can't serve as that guard — see above — and neither can
    /// `didConfigureChangeDetection` once its own async setup can fail or be
    /// aborted, since a bare bool set before the awaits would just recreate
    /// this task's Finding 2).
    ///
    /// It is keyed by epoch, not a plain bool, so that a root switch which
    /// lands while a pass is still suspended does not also block the
    /// FOLLOW-UP pass `restartAfterRootSwitch()` needs to launch for the new
    /// root: `quiesceForRootSwitch()` bumps `changeDetectionEpoch`, so the
    /// in-flight pass's captured epoch no longer matches, `start()` is free to
    /// launch a new pass for the current epoch, and the old pass's own
    /// completion (recognising the epoch has moved on again under it) skips
    /// clearing a marker that no longer belongs to it.
    private var configuringChangeDetectionEpoch: Int?

    /// Bumped by `quiesceForRootSwitch()` on every root switch. A
    /// configuration pass captures this at entry and re-checks it (via
    /// `mayInstallChangeDetection`) after every suspension point, right
    /// before it would install anything — see `configureChangeDetection`.
    private var changeDetectionEpoch = 0

    func start() {
        if !didConfigureChangeDetection && configuringChangeDetectionEpoch != changeDetectionEpoch {
            let epoch = changeDetectionEpoch
            configuringChangeDetectionEpoch = epoch
            Task {
                await configureChangeDetection(startedAtEpoch: epoch)
                // Only clear the marker if it still belongs to this pass —
                // a later pass (launched after a root switch moved the epoch
                // on while this one was still suspended) may have already
                // taken over.
                if configuringChangeDetectionEpoch == epoch {
                    configuringChangeDetectionEpoch = nil
                }
            }
        }
        guard Self.shouldStartReconcile(
            isReady: isReady,
            didReconcileSinceLaunch: didReconcileSinceLaunch
        ) else { return }
        Task {
            await reconcileNow()
            await refreshTotals()
            let isFirstReady = !isReady
            isReady = true
            // Cache enforcement belongs to the launch pass only, and only where
            // eviction means anything.
            if isFirstReady { await enforceCacheLimit() }
        }
    }

    /// Whether a configuration pass that began at `startedAtEpoch` may still
    /// install its trigger. A root switch bumps the epoch, so a pass that was
    /// already suspended when the switch happened must install nothing — it
    /// would otherwise point a watcher at the previous root, and leave two
    /// change-detection mechanisms live at once.
    nonisolated static func mayInstallChangeDetection(startedAtEpoch: Int, currentEpoch: Int) -> Bool {
        startedAtEpoch == currentEpoch
    }

    /// Picks the change-detection mechanism the active root supports:
    /// `NSMetadataQuery` under iCloud, a `DispatchSource` folder watcher for a
    /// custom root. Both funnel into the same debounced `reconcileScheduler`.
    ///
    /// This suspends twice — awaiting the container's capabilities, then (for
    /// a custom root) its items directory — and `quiesceForRootSwitch()` can
    /// land on the main actor in either gap. `startedAtEpoch` is re-checked
    /// against the live `changeDetectionEpoch` after EACH suspension, right
    /// before this would install anything, so a pass overtaken by a root
    /// switch installs nothing instead of arming a trigger for the root that
    /// is no longer active.
    private func configureChangeDetection(startedAtEpoch epoch: Int) async {
        let usesMetadataQuery = await LibraryContainer.shared.capabilities.usesMetadataQuery
        guard Self.mayInstallChangeDetection(
            startedAtEpoch: epoch, currentEpoch: changeDetectionEpoch
        ) else { return }

        if usesMetadataQuery {
            configureMetadataQuery()
            didConfigureChangeDetection = true
            return
        }

        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        guard Self.mayInstallChangeDetection(
            startedAtEpoch: epoch, currentEpoch: changeDetectionEpoch
        ) else { return }
        guard let watcher = LibraryFolderWatcher(url: dir, onChange: { [weak self] in
            Task { @MainActor in self?.handleQueryUpdate() }
        }) else { return }
        folderWatcher = watcher
        didConfigureChangeDetection = true
    }

    /// Stops every autonomous trigger ahead of a root switch. Does NOT wait for
    /// an in-flight scan — that is what `LibraryContainer.rootGeneration` and
    /// `LibraryIndexService.shouldApplyScan` are for. Nor does it wait for an
    /// in-flight `configureChangeDetection()` pass — bumping the epoch is what
    /// makes that pass's own re-checks a no-op instead.
    func quiesceForRootSwitch() async {
        changeDetectionEpoch += 1
        reconcileScheduler?.cancel()
        folderWatcher?.cancel()
        folderWatcher = nil
        if didConfigureChangeDetection {
            metadataQuery.stop()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
        didConfigureChangeDetection = false
        isReady = false
        didReconcileSinceLaunch = false
        // These two are "once per session" latches only because re-running the
        // backfills against the SAME Library would be pointless work. A root
        // switch makes that no longer true: the folder being opened is a
        // different set of items that has never been backfilled in this
        // process. Leaving them latched meant a newly opened root — an exported
        // folder, the headline use case — got no publish-date and no checkpoint
        // backfill at all until the app was relaunched.
        didRunDateBackfillThisSession = false
        didRunCheckpointBackfillThisSession = false
    }

    /// Re-arms everything against whatever root `LibraryContainer` now holds.
    func restartAfterRootSwitch() async {
        start()
    }

    /// Flips `didRunDateBackfillThisSession` so subsequent `LibraryView` mounts
    /// during the same session skip re-running the backfill.
    func markDateBackfillRanThisSession() {
        didRunDateBackfillThisSession = true
    }

    /// Same one-shot-per-session gate for the checkpoint (generation-data)
    /// backfill. Lives here rather than in the view so it survives
    /// `LibraryView` rebuilds — every navigation into the Library tab would
    /// otherwise restart it.
    func markCheckpointBackfillRanThisSession() {
        didRunCheckpointBackfillThisSession = true
    }

    /// Called by album operations (create/rename/delete/membership) to signal
    /// UI observers that album state has changed.
    func notifyAlbumsChanged() { albumsVersion += 1 }

    /// User-initiated publish-date catchup for a single item. Called from
    /// `LibraryDetailView` when the user opens an item whose `publishedAt`
    /// is still nil — this is the explicit recovery path for items the
    /// background scan has given up on (marker set). One API call, silent
    /// failure if anything goes wrong.
    func attemptPublishDateCatchup(for metadata: LibraryItemMetadata) async -> LibraryItemMetadata? {
        guard metadata.publishedAt == nil else { return nil }
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return nil }
        let svc = LibraryDateBackfillService(
            indexService: indexService,
            sidecarStore: FileLibraryBackfillSidecarStore(itemsDirectory: dir),
            fetcher: CivitaiServiceFetchImageAdapter()
        )
        return await svc.attemptCatchup(for: metadata)
    }

    /// Guards against overlapping reconciles. A reconcile `await`s a container
    /// scan that can take far longer than the scheduler's debounce window, so
    /// iCloud churn would otherwise stack many concurrent reconciles. We collapse
    /// any requests that arrive while one is running into a single trailing rerun.
    private var reconcileInFlight = false
    private var reconcileNeedsRerun = false

    /// Pure decision extracted from `reconcileNow` so it's directly
    /// unit-testable without touching the `LibraryVaultProvider.shared`
    /// singleton — mirrors `LibraryIndexService.shouldReconcile`. Only
    /// `.browsable` permits a reconcile/rebuild through `LibraryStore`.
    ///
    /// `reconcileNow` is the sole choke point for the two autonomous
    /// entry points that can fire on their own, unreachable by Task 17's
    /// `LibraryView` gate: the `NSMetadataQuery` change handler
    /// (`handleQueryUpdate` → `reconcileScheduler` → this method) and the
    /// launch-time `start()` reconcile (`ContentView.startLibrarySubsystem`
    /// calls `libraryStore.start()` unconditionally, before any unlock).
    /// `rebuildIndex()` reuses the same decision for the MANUAL Settings →
    /// "Rebuild Index" button, which is reachable any time Settings is —
    /// i.e. also before/during an unlock. `.migrating` and `.setupIncomplete`
    /// are UNLOCKED vault states, so `LibraryIndexService.shouldReconcile`'s
    /// Task 11b `.locked`-only check lets them through on its own — but the
    /// on-disk container is still half plaintext/half encrypted then, and a
    /// reconcile/rebuild would enumerate only the already-migrated files and
    /// prune the rest from the index.
    ///
    /// This must NOT gate `LibraryIndexService.reconcile`/`rebuild`
    /// themselves: the migration coordinator's own EXPLICIT end-of-migration
    /// rebuild (`LibraryEncryptionCoordinator.defaultRebuildIndex` →
    /// `LibrarySaveService.shared.indexService?.rebuild`) calls straight
    /// into `LibraryIndexService`, never through `LibraryStore`, and MUST
    /// still run while the gate is `.migrating` — that's what actually syncs
    /// the index after a migration. Gating only `LibraryStore`'s own
    /// `reconcileNow`/`rebuildIndex` call sites leaves that path untouched.
    nonisolated static func shouldAutonomousReconcile(
        givenLibraryGate gate: LibraryVaultProvider.LibraryGate
    ) -> Bool {
        gate == .browsable
    }

    /// `LibraryContainer.resolveItemsDirectory()`, with the one error that is a
    /// STATE rather than a hiccup promoted to the gate.
    ///
    /// A custom root can vanish mid-session — the volume is ejected, the folder
    /// renamed — and `LibraryContainer` reports exactly that as
    /// `LibraryRootError.unavailable(url)`. Swallowing it with `try?` (as every
    /// call site here originally did) left the gate `.browsable` over a stale
    /// index: images failed to load one by one and saves failed silently, with
    /// nothing on screen saying why. The folder watcher's own doc comment
    /// already promised this behaviour ("the reconcile it schedules will find
    /// the root unavailable and the gate will block"); this is what makes that
    /// true.
    ///
    /// Deliberately narrow. ONLY `.unavailable` blocks: it is the one error
    /// that means "the root you chose is not there", and it is unreachable
    /// under `.iCloud`, whose container is app-owned and created on demand.
    /// Every other failure (a full disk, a permissions blip) keeps the previous
    /// behaviour of returning quietly and retrying on the next pass, because
    /// gating the whole Library on a transient is its own harm.
    private func resolveItemsDirectoryReportingUnavailability() async -> (url: URL, generation: Int)? {
        do {
            return try await LibraryContainer.shared.resolveItemsDirectory()
        } catch {
            if let url = Self.rootUnavailableURL(from: error) {
                LibraryVaultProvider.shared.reportRootUnavailable(url)
            }
            return nil
        }
    }

    /// The folder to block on, or `nil` to keep today's quiet-retry behaviour.
    /// The whole of the "which failures gate the Library?" decision, pulled out
    /// `nonisolated static` so it is directly testable without a live container.
    nonisolated static func rootUnavailableURL(from error: Error) -> URL? {
        guard case LibraryRootError.unavailable(let url) = error else { return nil }
        return url
    }

    private func reconcileNow() async {
        let gate = LibraryVaultProvider.shared.libraryGate
        guard Self.shouldAutonomousReconcile(givenLibraryGate: gate) else {
            print("[LibraryStore] autonomous reconcile skipped; libraryGate=\(gate)")
            return
        }
        guard !reconcileInFlight else {
            reconcileNeedsRerun = true
            return
        }
        reconcileInFlight = true
        defer { reconcileInFlight = false }

        repeat {
            reconcileNeedsRerun = false
            guard let resolved = await resolveItemsDirectoryReportingUnavailability() else { return }
            iCloudStatus = await LibraryContainer.shared.isICloudBacked ? .available : .unavailable
            let outcome = await indexService.reconcile(
                itemsDirectory: resolved.url,
                startedAtGeneration: resolved.generation
            )
            let albumStateChanged = outcome.albumStateChanged
            applyPendingDownloads(from: outcome)
            // A reconcile has now actually reached the index service, so a
            // later `start()` (the post-unlock one) no longer needs to run a
            // catch-up pass. Set only here — past the gate guard above and past
            // the directory resolve — so a launch reconcile that was SKIPPED
            // never satisfies this latch.
            didReconcileSinceLaunch = true
            await refreshTotals()
            // Album rows / membership synced in from another device don't move
            // `itemCount`, so an open LibraryView would never reload without
            // this signal. Conditional, so quiet reconciles (the common case
            // under iCloud churn) don't trigger pointless reloads.
            if albumStateChanged { notifyAlbumsChanged() }
        } while reconcileNeedsRerun
    }

    /// Manual counterpart of `reconcileNow`'s gate: Settings → "Rebuild Index"
    /// is reachable any time the Library tab is (it's always in Settings,
    /// unlocked or not), so without this check a tap while `.migrating` or
    /// `.setupIncomplete` would prune the index against a half-migrated store
    /// exactly like the autonomous entry points BE-f closed. Reuses
    /// `shouldAutonomousReconcile` — the decision is identical: only
    /// `.browsable` may reconcile/rebuild through `LibraryStore`. Does NOT
    /// touch `LibraryIndexService.rebuild`/`reconcile` themselves, so the
    /// migration coordinator's own explicit end-of-migration rebuild
    /// (`LibraryEncryptionCoordinator.defaultRebuildIndex` →
    /// `LibrarySaveService.shared.indexService?.rebuild`, which never calls
    /// this method) is untouched and still runs while `.migrating`.
    func rebuildIndex() async {
        let gate = LibraryVaultProvider.shared.libraryGate
        guard Self.shouldAutonomousReconcile(givenLibraryGate: gate) else {
            print("[LibraryStore] manual rebuild skipped; libraryGate=\(gate)")
            return
        }
        guard let resolved = await resolveItemsDirectoryReportingUnavailability() else { return }
        let outcome = await indexService.rebuild(
            itemsDirectory: resolved.url,
            startedAtGeneration: resolved.generation
        )
        applyPendingDownloads(from: outcome)
        await refreshTotals()
        if outcome.albumStateChanged { notifyAlbumsChanged() }
    }

    // Both eviction entry points resolve the container first (fail fast, same
    // reasoning as `remove(itemID:)`) and then evict through the vault-aware
    // store, so an encrypted container's opaque `{token}.b` media is the file
    // actually targeted — the plaintext `mediaFileName` names nothing there.
    func freeUpSpaceNow() async {
        guard await LibraryContainer.shared.capabilities.supportsCacheLimit else { return }
        guard (try? await LibraryContainer.shared.itemsDirectory()) != nil else { return }
        await indexService.evictAllDownloaded(store: LibraryVaultProvider.shared.fileStore())
        await refreshTotals()
    }

    func enforceCacheLimit() async {
        guard await LibraryContainer.shared.capabilities.supportsCacheLimit else { return }
        guard (try? await LibraryContainer.shared.itemsDirectory()) != nil else { return }
        await indexService.enforceCacheLimit(
            maxBytes: cacheLimitBytes,
            store: LibraryVaultProvider.shared.fileStore()
        )
        await refreshTotals()
    }

    /// Dedicated serial queue for the blocking coordinated deletes below. Keeps
    /// the synchronous `NSFileCoordinator` + `FileManager.removeItem` syscalls
    /// (file coordination is a blocking iCloud/FileProvider round-trip) off the
    /// Swift concurrency cooperative pool — running them on `Task.detached` or
    /// any `async` context would burn cooperative threads and starve the pool,
    /// the documented "grey spinner" regression. Serial + utility QoS mirrors
    /// `LibraryIndexService.scanQueue`.
    nonisolated private static let deleteQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.delete",
        qos: .utility
    )

    /// Coordinates deletion of the given file URLs. `nonisolated` so it carries
    /// no actor isolation; the synchronous file coordination must run on
    /// `deleteQueue`, never the main actor. Missing files are skipped.
    nonisolated static func deleteFiles(at urls: [URL]) {
        let coordinator = NSFileCoordinator()
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var err: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    /// Coordinates deletion of both files for each item id via the store:
    /// `store.removeItem(itemID:plaintextExtension:)` deletes that item's
    /// metadata + media, whatever their on-disk names actually are (plaintext
    /// `{id}.json`/`.jpeg`/`.mp4`, or the opaque encrypted `*.m`/`*.b` tokens).
    /// Trying both "jpeg" and "mp4" per item mirrors today's brute-force
    /// extension list — the caller doesn't know an item's actual media type,
    /// and `removeItem` silently skips files that don't exist (and ignores
    /// the extension entirely once encrypted, since the opaque media name
    /// doesn't depend on it), so the second call is a harmless no-op either
    /// way. Missing files are skipped. Shared by `remove(itemID:)` and
    /// `remove(itemIDs:)`.
    nonisolated static func deleteItemFiles(itemIDs: [Int], store: LibraryFileStore) {
        for itemID in itemIDs {
            store.removeItem(itemID: itemID, plaintextExtension: "jpeg")
            store.removeItem(itemID: itemID, plaintextExtension: "mp4")
        }
    }

    /// Directory-based convenience for callers/tests without a store handy —
    /// builds a passthrough one (`crypto: nil`) and deletes through it. Byte
    /// -identical to deleting `{id}.json`/`.jpeg`/`.mp4` directly, which is all
    /// a passthrough store's `removeItem` does. Encrypted vaults must go
    /// through `deleteItemFiles(itemIDs:store:)` instead, with the real store.
    nonisolated static func deleteItemFiles(itemIDs: [Int], in dir: URL) {
        deleteItemFiles(itemIDs: itemIDs, store: LibraryFileStore(itemsDirectory: dir, crypto: nil))
    }

    /// Runs `deleteItemFiles` on `deleteQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread or the main actor.
    nonisolated static func runDeleteItemFiles(itemIDs: [Int], store: LibraryFileStore) async {
        await withCheckedContinuation { continuation in
            deleteQueue.async {
                deleteItemFiles(itemIDs: itemIDs, store: store)
                continuation.resume()
            }
        }
    }

    /// Directory-based convenience mirroring `deleteItemFiles(itemIDs:in:)` —
    /// plaintext-only, kept for direct callers/tests.
    nonisolated static func runDeleteItemFiles(itemIDs: [Int], in dir: URL) async {
        await runDeleteItemFiles(itemIDs: itemIDs, store: LibraryFileStore(itemsDirectory: dir, crypto: nil))
    }

    /// Enumerates and deletes every file in `dir` on `deleteQueue` (the
    /// directory walk is blocking I/O too), suspending the caller until done.
    /// Backs `resetLibrary()`.
    nonisolated static func runDeleteAllContents(in dir: URL) async {
        await withCheckedContinuation { continuation in
            deleteQueue.async {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? []
                deleteFiles(at: contents)
                continuation.resume()
            }
        }
    }

    func remove(itemID: Int) async {
        // Resolve up front so a failure (iCloud unavailable, disk full, etc.)
        // fails fast instead of silently deleting into `fileStore()`'s temp
        // scratch fallback — same reasoning as `LibrarySaveService.performSave`.
        guard (try? await LibraryContainer.shared.itemsDirectory()) != nil else { return }
        let store = await LibraryVaultProvider.shared.fileStore()
        await Self.runDeleteItemFiles(itemIDs: [itemID], store: store)
        await indexService.remove(itemID: itemID)
        await refreshTotals()
    }

    /// Batch delete for the Library multi-select action. Resolves the items
    /// directory once, deletes all files, removes all index rows in a single
    /// save, then refreshes totals once — so removing N items is not N directory
    /// resolves and N totals refreshes. File coordination runs off the main
    /// actor so a large multi-select can't hitch the UI.
    func remove(itemIDs: [Int]) async {
        guard !itemIDs.isEmpty else { return }
        guard (try? await LibraryContainer.shared.itemsDirectory()) != nil else { return }
        let store = await LibraryVaultProvider.shared.fileStore()
        await Self.runDeleteItemFiles(itemIDs: itemIDs, store: store)
        await indexService.remove(itemIDs: itemIDs)
        await refreshTotals()
    }

    func resetLibrary() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        await Self.runDeleteAllContents(in: dir)
        await indexService.wipe()
        await refreshTotals()
    }

    /// Folds a completed scan's pending counts into `downloadProgress`. A
    /// reconcile that never scanned (`nil` counts) leaves the last known figure
    /// untouched rather than reporting a misleading zero.
    ///
    /// Items and albums are summed into one backlog: both are content the user
    /// can't see yet, and the stall clock only needs to know whether ANY of it
    /// moved. The split stays available on the outcome for callers that want to
    /// word things more precisely.
    private func applyPendingDownloads(from outcome: LibraryIndexService.ReconcileOutcome) {
        guard let items = outcome.pendingItems else { return }
        let total = items + (outcome.pendingAlbums ?? 0)
        downloadProgress = downloadProgress.recording(pending: total, now: Date())
    }

    private func refreshTotals() async {
        let summary = await indexService.summary()
        downloadedBytes = summary.downloadedBytes
        itemCount = summary.itemCount
        // Feeds badge items that are already in the library from this set; it
        // rides along on the pass above rather than costing its own query.
        LibrarySaveService.shared.setSavedItemIDs(summary.savedItemIDs)
    }

    // MARK: - NSMetadataQuery

    private func configureMetadataQuery() {
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Plaintext item/album sidecars (`*.json`), encrypted item sidecars
        // (`*.m`), and encrypted aux files — album files and, later,
        // sort-assistant state (`*.x`) — all need to trigger a reconcile when
        // they change on another device. Encrypted media (`*.b`) deliberately
        // does not: the index is built from sidecars, not media.
        metadataQuery.predicate = NSPredicate(
            format: "%K LIKE '*.json' OR %K LIKE '*.m' OR %K LIKE '*.x'",
            NSMetadataItemFSNameKey, NSMetadataItemFSNameKey, NSMetadataItemFSNameKey
        )
        // Run gathering/merge off the main thread (see `metadataQueue`).
        metadataQuery.operationQueue = metadataQueue

        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering,
                     Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(
                forName: name,
                object: metadataQuery,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleQueryUpdate() }
            })
        }
        metadataQuery.start()
    }

    private func handleQueryUpdate() {
        // A sidecar appeared or changed in iCloud (e.g. an item saved on
        // another device synced in). Coalesce the bursts into a single reconcile.
        reconcileScheduler?.schedule()
    }
}
