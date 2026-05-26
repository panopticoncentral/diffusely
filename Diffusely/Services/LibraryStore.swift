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
    /// itemID -> download progress (0...1) while a media file is materializing.
    @Published private(set) var downloadProgress: [Int: Double] = [:]
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

    func reconcileNow() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        iCloudStatus = await LibraryContainer.shared.isICloudBacked ? .available : .unavailable
        await indexService.reconcile(itemsDirectory: dir)
        await refreshTotals()
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

    func remove(itemID: Int) async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        let coordinator = NSFileCoordinator()
        for name in ["\(itemID).json", "\(itemID).jpeg", "\(itemID).mp4"] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var err: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                try? FileManager.default.removeItem(at: u)
            }
        }
        await indexService.remove(itemID: itemID)
        await refreshTotals()
    }

    func resetLibrary() async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        let coordinator = NSFileCoordinator()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            var err: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                try? FileManager.default.removeItem(at: u)
            }
        }
        await indexService.wipe()
        downloadProgress = [:]
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
        metadataQuery.disableUpdates()
        var progress: [Int: Double] = [:]
        for i in 0..<metadataQuery.resultCount {
            guard let item = metadataQuery.result(at: i) as? NSMetadataItem else { continue }
            if let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
               let pct = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                let stem = (name as NSString).deletingPathExtension
                if let id = Int(stem), pct < 100 { progress[id] = pct / 100.0 }
            }
        }
        downloadProgress = progress
        metadataQuery.enableUpdates()
        reconcileScheduler?.schedule()
    }
}
