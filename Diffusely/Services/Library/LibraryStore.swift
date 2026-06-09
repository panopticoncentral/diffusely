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

    static let cacheLimitDefaultsKey = "library_cache_limit_bytes"
    static let defaultCacheLimitBytes = 2 * 1024 * 1024 * 1024  // 2 GB

    let indexService: LibraryIndexService

    private let metadataQuery = NSMetadataQuery()
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

    func start() {
        guard !isReady else { return }
        Task {
            await reconcileNow()
            await refreshTotals()
            isReady = true
            await enforceCacheLimit()
        }
        configureMetadataQuery()
    }

    /// Flips `didRunDateBackfillThisSession` so subsequent `LibraryView` mounts
    /// during the same session skip re-running the backfill.
    func markDateBackfillRanThisSession() {
        didRunDateBackfillThisSession = true
    }

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

    private func reconcileNow() async {
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
            await indexService.reconcile(itemsDirectory: dir)
            await refreshTotals()
        } while reconcileNeedsRerun
    }

    func rebuildIndex() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        await indexService.rebuild(itemsDirectory: dir)
        await refreshTotals()
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

    /// Coordinates deletion of the on-disk files (`{id}.json` / `.jpeg` / `.mp4`)
    /// for the given ids. Static and directory-injected so it is unit-testable
    /// against a temp directory without the iCloud container. Missing files are
    /// skipped. Shared by `remove(itemID:)` and `remove(itemIDs:)`.
    nonisolated static func deleteItemFiles(itemIDs: [Int], in dir: URL) {
        let urls = itemIDs.flatMap { itemID in
            ["\(itemID).json", "\(itemID).jpeg", "\(itemID).mp4"]
                .map { dir.appendingPathComponent($0) }
        }
        deleteFiles(at: urls)
    }

    /// Runs `deleteItemFiles` on `deleteQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread or the main actor.
    nonisolated static func runDeleteItemFiles(itemIDs: [Int], in dir: URL) async {
        await withCheckedContinuation { continuation in
            deleteQueue.async {
                deleteItemFiles(itemIDs: itemIDs, in: dir)
                continuation.resume()
            }
        }
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
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        await Self.runDeleteItemFiles(itemIDs: [itemID], in: dir)
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
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        await Self.runDeleteItemFiles(itemIDs: itemIDs, in: dir)
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
        metadataQuery.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)

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
