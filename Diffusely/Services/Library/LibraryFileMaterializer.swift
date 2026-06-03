import Foundation

/// Drives on-demand iCloud materialization of a personal-library file: reports
/// whether the file is already local, and triggers a download + poll when it
/// isn't. Extracted from `LibraryMediaLoader` so both the image-loading path
/// (the Nuke data closure in `LibraryImageRequest`) and the video player path
/// share one implementation. Nonisolated: all work is filesystem / iCloud
/// metadata, safe off the main actor.
enum LibraryFileMaterializer {
    private enum Readiness { case ready, needsDownload }

    /// True if the file is present locally — a non-ubiquitous file that exists,
    /// or a ubiquitous item whose download status is `.current` / `.downloaded`.
    /// Runs the (potentially blocking under a cold cache) iCloud metadata lookup
    /// off the main actor.
    static func isReady(url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            checkLocalReadiness(at: url) == .ready
        }.value
    }

    /// Triggers an iCloud download and polls until the file is current/downloaded
    /// (~2-minute ceiling). Throws `CancellationError` if cancelled mid-poll and
    /// `URLError(.timedOut)` if the ceiling is hit. Call only after `isReady`
    /// returned false.
    static func download(url: URL) async throws {
        // Only a genuine iCloud (ubiquitous) item can be materialized on demand.
        // A target that is absent and NOT a ubiquitous item — a local-only
        // fallback file that was deleted, or a sidecar whose media was never
        // written/uploaded — has nothing to fetch. Yet because the path lives
        // inside the iCloud container, `startDownloadingUbiquitousItem` accepts
        // it and asynchronously spawns a doomed in-process download task (logged
        // as "LocalDownloadTask … finished with error [-1002] unsupported URL",
        // keyed by the item's iCloud document UUID). The Library cascade re-runs
        // on every grid/video reappearance, so that one impossible item becomes a
        // console error storm. Probe the item's iCloud status first and fail fast
        // for the impossible case instead of issuing the doomed task.
        let isUbiquitous = await Task.detached(priority: .userInitiated) {
            (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        }.value
        guard isUbiquitous else {
            throw URLError(.fileDoesNotExist)
        }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let path = url.path
        for _ in 0..<240 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let downloaded = await Task.detached(priority: .userInitiated) {
                // Fresh URL each iteration: `URL` caches resource values on its
                // backing object, so reusing one would report the status captured
                // on the first read (.notDownloaded) forever and the poll would
                // never observe completion — the thumbnail would spin until the
                // 2-minute timeout even after the file arrived.
                let probe = URL(fileURLWithPath: path)
                let status = (try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
                return status == .current || status == .downloaded
            }.value
            if downloaded { return }
        }
        throw URLError(.timedOut)
    }

    /// Pure snapshot of the on-disk + iCloud-status view of `url`. Touches only
    /// `FileManager.default` and `URL` resource keys, so it's safe on any thread.
    private static func checkLocalReadiness(at url: URL) -> Readiness {
        let fileManager = FileManager.default
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        // Non-ubiquitous local file that exists: ready immediately.
        if values?.isUbiquitousItem != true, fileManager.fileExists(atPath: url.path) {
            return .ready
        }
        if values?.ubiquitousItemDownloadingStatus == .current
            || values?.ubiquitousItemDownloadingStatus == .downloaded {
            return .ready
        }
        return .needsDownload
    }
}
