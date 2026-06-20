import Foundation

/// Drives on-demand iCloud materialization of a personal-library file: reports
/// whether the file is already local, and triggers a download + poll when it
/// isn't. Extracted from `LibraryMediaLoader` so both the image-loading path
/// (the Nuke data closure in `LibraryImageRequest`) and the video player path
/// share one implementation. Nonisolated: all work is filesystem / iCloud
/// metadata, safe off the main actor.
enum LibraryFileMaterializer {
    private enum Readiness { case ready, needsDownload }

    /// Dedicated queue for the blocking iCloud status reads below. A cold-cache
    /// `resourceValues(forKeys:)` is a blocking XPC round-trip to fileproviderd,
    /// so it MUST stay off the Swift concurrency cooperative pool — running it on
    /// `Task.detached` lets an album's worth of probes occupy every cooperative
    /// thread, wedging all async work app-wide on permanent grey spinners. See
    /// the "grey-spinner cooperative-pool-starvation" recurring bug.
    private static let ioQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.materializer",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs `work` on `ioQueue` and suspends the caller until it finishes —
    /// without occupying a cooperative thread.
    private static func runIO<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// True if the file is present locally — a non-ubiquitous file that exists,
    /// or a ubiquitous item whose download status is `.current` / `.downloaded`.
    /// Runs the (potentially blocking under a cold cache) iCloud metadata lookup
    /// off the main actor.
    static func isReady(url: URL) async -> Bool {
        await runIO { checkLocalReadiness(at: url) == .ready }
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
        let isUbiquitous = await runIO {
            (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        }
        guard isUbiquitous else {
            throw URLError(.fileDoesNotExist)
        }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let path = url.path
        for _ in 0..<240 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let downloaded = await runIO {
                // Fresh URL each iteration: `URL` caches resource values on its
                // backing object, so reusing one would report the status captured
                // on the first read (.notDownloaded) forever and the poll would
                // never observe completion — the thumbnail would spin until the
                // 2-minute timeout even after the file arrived.
                let probe = URL(fileURLWithPath: path)
                let status = (try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
                return status == .current || status == .downloaded
            }
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
