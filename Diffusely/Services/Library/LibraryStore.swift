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
    /// Bumped whenever an album is created/renamed/deleted or membership changes
    /// — by local edits (views call `notifyAlbumsChanged()`) and by reconciles
    /// that ingest album/membership changes synced in from another device.
    /// `LibraryView` observes this to reload, since membership edits don't change
    /// `itemCount`.
    @Published private(set) var albumsVersion: Int = 0

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

    init(modelContainer: ModelContainer) {
        self.indexService = LibraryIndexService(modelContainer: modelContainer)
        self.albumService = LibraryAlbumService(
            index: indexService,
            itemsDirectory: { try? await LibraryContainer.shared.itemsDirectory() }
        )
        LibrarySaveService.shared.indexService = indexService
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

    /// Set once a reconcile has actually reached the index service — see
    /// `shouldStartReconcile` for why `isReady` can't serve as this latch.
    private var didReconcileSinceLaunch = false

    /// Separate one-shot latch for the metadata query. `isReady` used to serve
    /// double duty here, but it only flips once the first reconcile completes,
    /// so it can't guard a synchronous exactly-once setup against two `start()`
    /// calls in quick succession.
    private var didConfigureMetadataQuery = false

    func start() {
        if !didConfigureMetadataQuery {
            didConfigureMetadataQuery = true
            configureMetadataQuery()
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
            // Cache enforcement belongs to the launch pass only; a post-unlock
            // catch-up reconcile shouldn't also start evicting media.
            if isFirstReady { await enforceCacheLimit() }
        }
    }

    /// Flips `didRunDateBackfillThisSession` so subsequent `LibraryView` mounts
    /// during the same session skip re-running the backfill.
    func markDateBackfillRanThisSession() {
        didRunDateBackfillThisSession = true
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
            guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
            iCloudStatus = await LibraryContainer.shared.isICloudBacked ? .available : .unavailable
            let albumStateChanged = await indexService.reconcile(itemsDirectory: dir)
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
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        let albumStateChanged = await indexService.rebuild(itemsDirectory: dir)
        await refreshTotals()
        if albumStateChanged { notifyAlbumsChanged() }
    }

    func freeUpSpaceNow() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        await indexService.evictAllDownloaded(itemsDirectory: dir)
        await refreshTotals()
    }

    func enforceCacheLimit() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        await indexService.enforceCacheLimit(maxBytes: cacheLimitBytes, itemsDirectory: dir)
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

    private func refreshTotals() async {
        downloadedBytes = await indexService.totalDownloadedBytes()
        itemCount = await indexService.itemCount()
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
