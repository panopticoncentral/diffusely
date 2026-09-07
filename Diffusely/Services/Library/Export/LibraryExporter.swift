import Foundation
import CryptoKit

/// Writes a complete, decrypted copy of the Library container into a
/// destination folder, in the app's own plaintext layout (`<id>.jpeg` /
/// `<id>.mp4` + `<id>.json`, plus `album-<uuid>.json`).
///
/// Synchronous and nonisolated by design: every step here blocks (coordinated
/// reads, iCloud waits, AES-GCM opens), so the whole run belongs on a
/// dedicated queue — `LibraryExportService` provides one. Never call it from
/// the cooperative pool; see the "grey-spinner cooperative-pool-starvation"
/// bug class.
///
/// Unlike `LibraryEncryptionMigrator`, which stops on the first failure
/// because it mutates the live Library, this is a pure reader and collects
/// failures instead: an archive that aborts at item 400 of 6,500 because one
/// file is unreachable is worse than useless.
struct LibraryExporter {
    /// How far ahead of the write cursor the read-ahead cursor runs, kicking
    /// iCloud downloads so they proceed in parallel instead of one at a time.
    static let prefetchWindow = 16

    /// Written in the destination root, and ONLY when something failed. It
    /// describes the most recent run alone: any existing copy is removed at
    /// the start of a run, so a clean re-run never leaves a stale report
    /// claiming failures that have since been resolved. Deliberately not
    /// `.json` — the folder is meant to stay usable as a Library later, and
    /// the app enumerates `*.json` there.
    static let failuresFileName = "_DiffuselyExport-failures.txt"

    let store: LibraryFileStore
    let destination: URL

    /// How many items the SwiftData index believed the container holds, from
    /// the pre-flight plan. Recorded on the summary beside the count the
    /// container walk actually produced so a short walk — an evicted or
    /// unresolved container, a `contentsOfDirectory` that threw and was
    /// swallowed into `[]` — cannot be reported as a complete export. Zero
    /// means "no estimate", never "no items".
    let indexedItemCount: Int

    /// Blocks until `url` is local, returning nil on success or the failure.
    /// Injected so tests never touch iCloud.
    let materialize: (URL) -> Error?
    /// Fire-and-forget download kick for a file the write cursor hasn't
    /// reached yet.
    let startPrefetch: (URL) -> Void
    let shouldCancel: () -> Bool

    init(store: LibraryFileStore,
         destination: URL,
         indexedItemCount: Int = 0,
         materialize: ((URL) -> Error?)? = nil,
         startPrefetch: @escaping (URL) -> Void = LibraryExporter.kickDownload,
         shouldCancel: @escaping () -> Bool = { false }) {
        self.store = store
        self.destination = destination
        self.indexedItemCount = indexedItemCount
        self.startPrefetch = startPrefetch
        self.shouldCancel = shouldCancel
        self.materialize = materialize
            ?? LibraryExporter.makeBlockingMaterializer(shouldCancel: shouldCancel)
    }

    // MARK: Pipeline records

    /// An item the read-ahead cursor has resolved, ready for the write cursor.
    private struct Prepared {
        let itemID: Int
        let plaintextExtension: String
        let mediaName: String
        let sidecarName: String
        /// Verbatim decrypted sidecar bytes — written unchanged.
        let sidecarBytes: Data
        let expectedSHA256: String
    }

    private enum Step {
        case ready(Prepared)
        case skip
        case failure(LibraryExportFailure)
        /// Abandoned because the run is being cancelled — counted as nothing
        /// at all. NOT a failure: a cancelled download is the user's own
        /// doing, and recording it would have Cancel produce a window's worth
        /// of bogus `.downloadFailed` entries and a failures file claiming
        /// they failed.
        case cancelled
    }

    // MARK: Run

    func run(progress: (Int, Int) -> Void) -> LibraryExportSummary {
        var summary = LibraryExportSummary()
        sweepPartials()
        removeFailuresFile()

        // Sorted so progress advances in a stable, comprehensible order and
        // an interrupted run resumes over the same sequence.
        let sources = store.enumerateMetadataFiles()
            .filter(isItemSidecar)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let total = sources.count
        let existing = destinationNames()

        // The two halves of the spec's hybrid enumeration, recorded together
        // so the summary can report their delta in either direction: surplus
        // ("6 items on disk weren't in the index") is informational, shortfall
        // is a warning that this archive may be missing items.
        summary.enumeratedItems = total
        summary.indexedItems = indexedItemCount

        var queue: [Step] = []
        var nextToPrepare = 0
        var done = 0

        while true {
            if shouldCancel() {
                summary.cancelled = true
                break
            }

            // Read-ahead cursor: top the queue back up to the window, kicking
            // an iCloud download for each newly prepared item's media.
            //
            // The cancellation check belongs HERE too, not only at the top of
            // the outer loop: `prepare` blocks in `materialize`, so Cancel
            // routinely lands mid-top-up. Without this the loop would keep
            // preparing until the 16-slot window filled, each call returning
            // instantly with a `CancellationError`.
            while queue.count < Self.prefetchWindow, nextToPrepare < sources.count {
                // Must set `summary.cancelled` here too, not just at the outer
                // check above: if Cancel lands between the two (reachable on
                // the very first iteration, while `queue` is still empty),
                // this `break` falls straight through the `guard !queue.isEmpty`
                // below into an unqualified "completed" run — the exact
                // short-run-reads-as-success failure this summary field exists
                // to prevent, reintroduced through this very break.
                if shouldCancel() {
                    summary.cancelled = true
                    break
                }
                let step = prepare(sources[nextToPrepare], existing: existing)
                nextToPrepare += 1
                if case .ready(let item) = step {
                    startPrefetch(store.mediaURL(itemID: item.itemID,
                                                 plaintextExtension: item.plaintextExtension))
                }
                queue.append(step)
            }

            guard !queue.isEmpty else { break }

            // Write cursor: strictly one item at a time, in order.
            switch queue.removeFirst() {
            case .ready(let item):
                write(item, into: &summary)
            case .skip:
                summary.skipped += 1
            case .failure(let failure):
                summary.failures.append(failure)
            case .cancelled:
                break
            }
            done += 1
            progress(done, total)
        }

        if !summary.cancelled {
            exportAlbums(into: &summary)
        }

        if !summary.failures.isEmpty {
            writeFailuresFile(summary.failures)
        }

        return summary
    }

    // MARK: Read-ahead

    /// True when `url` (already filtered by `store.enumerateMetadataFiles()`)
    /// is an actual item sidecar, not merely something that shares the
    /// store's metadata-file naming convention.
    ///
    /// `LibraryFileStore.isMetadataFileName` classifies a plaintext store's
    /// metadata files by the bare `*.json` suffix — deliberately broad, and
    /// shared on purpose with `album-<uuid>.json` and
    /// `SortAssistantStateStore.fileName` ("sort-assistant-state.json"),
    /// both of which live in the same `itemsDirectory`. Widening that shared
    /// classification would ripple into its other callers
    /// (`LibraryIndexService`, `LibraryEncryptionMigrator`), which already
    /// cope with the broad match in their own ways, so the exporter filters
    /// locally instead: a real item sidecar's filename stem is always the
    /// item's numeric id, while `album-*` and `sort-assistant-state` are not.
    /// Without this, every plaintext export of a library with any album (or
    /// sort-assistant state) would hand those files to `prepare(_:existing:)`,
    /// which decodes them as `LibraryItemMetadata`, fails, and records a
    /// spurious `.sidecarUndecodable` failure.
    ///
    /// Encrypted stores need no such filter: `.m` is item-metadata only,
    /// since aux files use `.x` and media uses `.b`. Classifying by content
    /// there would mean decrypting every file just to sort it, doubling the
    /// I/O on every item in the run — so encrypted sources pass through
    /// unfiltered.
    private func isItemSidecar(_ url: URL) -> Bool {
        store.isEncrypted || Int(url.deletingPathExtension().lastPathComponent) != nil
    }

    private func prepare(_ url: URL, existing: Set<String>) -> Step {
        let name = url.lastPathComponent

        if let error = materialize(url) {
            guard !isCancellation(error) else { return .cancelled }
            return .failure(LibraryExportFailure(
                itemID: nil, fileName: name,
                reason: .downloadFailed(error.localizedDescription)))
        }
        guard let bytes = store.readMetadata(at: url) else {
            return .failure(LibraryExportFailure(
                itemID: nil, fileName: name, reason: .sidecarUnreadable))
        }
        guard let metadata = try? LibraryItemMetadata.decoder()
            .decode(LibraryItemMetadata.self, from: bytes) else {
            return .failure(LibraryExportFailure(
                itemID: nil, fileName: name, reason: .sidecarUndecodable))
        }

        let ext = metadata.mediaType.fileExtension
        let mediaName = "\(metadata.itemID).\(ext)"
        let sidecarName = "\(metadata.itemID).json"
        if existing.contains(mediaName), existing.contains(sidecarName) {
            return .skip
        }

        return .ready(Prepared(
            itemID: metadata.itemID,
            plaintextExtension: ext,
            mediaName: mediaName,
            sidecarName: sidecarName,
            sidecarBytes: bytes,
            expectedSHA256: metadata.contentSHA256))
    }

    // MARK: Write

    private func write(_ item: Prepared, into summary: inout LibraryExportSummary) {
        let mediaURL = store.mediaURL(itemID: item.itemID,
                                      plaintextExtension: item.plaintextExtension)
        if let error = materialize(mediaURL) {
            // A download the user cancelled is not a download that failed.
            guard !isCancellation(error) else { return }
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName,
                reason: .downloadFailed(error.localizedDescription)))
            return
        }
        guard let media = store.readMedia(itemID: item.itemID,
                                          plaintextExtension: item.plaintextExtension) else {
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName, reason: .mediaMissing))
            return
        }

        // A mismatch is reported but does NOT stop the write: the container's
        // copy may be the only other copy, so refusing to back it up would
        // turn one suspect copy into one suspect copy and no backup.
        //
        // Recorded only once the write has actually succeeded, so a mismatched
        // item whose write then fails yields ONE failure (the write), not two
        // for the same item — which had the sheet reporting "2 items failed"
        // for a single item.
        let mismatched = hexDigest(of: media) != item.expectedSHA256

        do {
            try writeAtomically(media, name: item.mediaName)
            try writeAtomically(item.sidecarBytes, name: item.sidecarName)
            summary.exported += 1
            // Both files land on the destination, so both count — the album
            // pass already counts its payload, and omitting the sidecar here
            // under-reported every run.
            summary.bytesWritten += media.count + item.sidecarBytes.count
            if mismatched {
                summary.failures.append(LibraryExportFailure(
                    itemID: item.itemID, fileName: item.mediaName, reason: .integrityMismatch))
            }
        } catch {
            summary.failures.append(LibraryExportFailure(
                itemID: item.itemID, fileName: item.mediaName,
                reason: .writeFailed(error.localizedDescription)))
        }
    }

    /// True when `error` is the run being cancelled rather than a real
    /// failure. Covers both the direct `CancellationError` the bridged
    /// materializer surfaces and the window after the flag trips, where
    /// already-issued waits unwind with whatever error they were mid-flight
    /// on.
    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || shouldCancel()
    }

    /// Writes via `.<name>.partial` then an atomic rename, so a killed run
    /// never leaves a truncated file under a real name. That is precisely what
    /// makes skip-if-exists trustworthy on the next run.
    private func writeAtomically(_ data: Data, name: String) throws {
        let final = destination.appendingPathComponent(name)
        let partial = destination.appendingPathComponent(".\(name).partial")
        let fileManager = FileManager.default
        try data.write(to: partial, options: .atomic)
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
        }
        try fileManager.moveItem(at: partial, to: final)
    }

    // MARK: Albums

    /// Album records (name, description, AI profile). Membership is NOT here —
    /// it lives on each item's sidecar, which the item pass already copied.
    ///
    /// Plaintext stores keep their literal `album-<uuid>.json` names, so they
    /// are enumerated by prefix. Encrypted stores share one opaque `.x`
    /// namespace between album files and the sort-assistant state, with no
    /// filename hint, so albums are recovered by decode-and-classify —
    /// the approach `LibraryEncryptionMigrator.decryptAux` established.
    private func exportAlbums(into summary: inout LibraryExportSummary) {
        let existing = destinationNames()
        for (name, payload) in albumPayloads(into: &summary) {
            guard !existing.contains(name) else { continue }
            do {
                try writeAtomically(payload, name: name)
                summary.albumsExported += 1
                summary.bytesWritten += payload.count
            } catch {
                summary.failures.append(LibraryExportFailure(
                    itemID: nil, fileName: name,
                    reason: .writeFailed(error.localizedDescription)))
            }
        }
    }

    /// `(destination file name, bytes)` for every album file in the container.
    ///
    /// A file that cannot be READ (missing, or failing to decrypt) is recorded
    /// as an `.albumUnreadable` failure in both modes: every other omission in
    /// this engine produces a `LibraryExportFailure`, and a corrupt album file
    /// vanishing from the archive without a word is exactly the silence this
    /// engine otherwise avoids. Reading is never the classification path, so
    /// reporting here is always safe.
    ///
    /// A file that reads but does not DECODE is treated differently per mode,
    /// and the difference is load-bearing:
    /// - Encrypted: decode failure IS the classification — album files and the
    ///   sort-assistant state share one opaque `.x` namespace with no filename
    ///   hint, and "doesn't decode as a `LibraryAlbumFile`" is precisely how
    ///   the non-album files are told apart. Reporting it would make every
    ///   encrypted export with sort-assistant state claim a failure. Silent by
    ///   design.
    /// - Plaintext: no decode happens at all. The `album-<uuid>.json` filename
    ///   has already identified the file, and the bytes are copied verbatim —
    ///   the same fidelity rule the item sidecars follow. Decoding just to
    ///   validate would risk refusing to back up an album file the current
    ///   struct can't parse.
    private func albumPayloads(into summary: inout LibraryExportSummary) -> [(String, Data)] {
        if store.isEncrypted {
            var payloads: [(String, Data)] = []
            for url in store.enumerateAuxFiles() {
                guard materializeAux(url, named: url.lastPathComponent, into: &summary) else { continue }
                guard let payload = store.readAux(at: url) else {
                    summary.failures.append(LibraryExportFailure(
                        itemID: nil, fileName: url.lastPathComponent,
                        reason: .albumUnreadable))
                    continue
                }
                guard let album = try? LibraryAlbumFile.decoder()
                    .decode(LibraryAlbumFile.self, from: payload) else { continue }
                payloads.append((LibraryAlbumStore.fileName(for: album.id), payload))
            }
            return payloads
        }

        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: store.itemsDirectory.path)) ?? []
        var payloads: [(String, Data)] = []
        for name in names.sorted() where LibraryAlbumStore.albumID(fromFileName: name) != nil {
            guard materializeAux(store.auxURL(name: name), named: name, into: &summary) else { continue }
            guard let payload = store.readAux(name: name) else {
                summary.failures.append(LibraryExportFailure(
                    itemID: nil, fileName: name, reason: .albumUnreadable))
                continue
            }
            payloads.append((name, payload))
        }
        return payloads
    }

    /// Brings one aux file local before it is read, returning false when the
    /// caller must skip it.
    ///
    /// Aux files live in the same evictable container as items, so they need
    /// the same treatment the item pass gives sidecars and media — and for a
    /// sharper reason than "the read might fail". A coordinated read of a
    /// dataless iCloud file blocks in `read(2)` indefinitely and cannot be
    /// interrupted, so an evicted album file would wedge the export at the
    /// very end of the run, past the point where `shouldCancel` is consulted:
    /// the user could neither finish nor cancel, only force-quit. Probing and
    /// downloading first is what keeps that read non-blocking.
    ///
    /// A cancel landing mid-download is silent, matching `write(_:into:)` — a
    /// download the user cancelled is not a download that failed.
    private func materializeAux(
        _ url: URL,
        named name: String,
        into summary: inout LibraryExportSummary
    ) -> Bool {
        guard let error = materialize(url) else { return true }
        guard !isCancellation(error) else { return false }
        summary.failures.append(LibraryExportFailure(
            itemID: nil, fileName: name,
            reason: .downloadFailed(error.localizedDescription)))
        return false
    }

    // MARK: Helpers

    private func destinationNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
    }

    private func sweepPartials() {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: destination.appendingPathComponent(name))
        }
    }

    private var failuresFileURL: URL {
        destination.appendingPathComponent(Self.failuresFileName)
    }

    private func removeFailuresFile() {
        try? FileManager.default.removeItem(at: failuresFileURL)
    }

    private func writeFailuresFile(_ failures: [LibraryExportFailure]) {
        var lines = [
            "Diffusely library export — \(ISO8601DateFormatter().string(from: Date()))",
            "\(failures.count) item(s) did not export cleanly.",
            ""
        ]
        for failure in failures {
            let id = failure.itemID.map(String.init) ?? "unknown"
            lines.append("item \(id)  (\(failure.fileName))  — \(Self.describe(failure.reason))")
        }
        try? Data(lines.joined(separator: "\n").appending("\n").utf8)
            .write(to: failuresFileURL, options: .atomic)
    }

    private static func describe(_ reason: LibraryExportFailure.Reason) -> String {
        switch reason {
        case .sidecarUnreadable:
            return "sidecar could not be read or decrypted"
        case .sidecarUndecodable:
            return "sidecar is not valid item metadata"
        case .mediaMissing:
            return "media file missing or unreadable"
        case .downloadFailed(let message):
            return "iCloud download failed: \(message)"
        case .integrityMismatch:
            return "media does not match its recorded SHA-256 — EXPORTED ANYWAY, verify this file"
        case .albumUnreadable:
            return "album file could not be read or decrypted"
        case .writeFailed(let message):
            return "could not write to the destination: \(message)"
        }
    }

    private func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Default iCloud bridges

    /// Box for carrying a result out of the bridged `Task` below. The
    /// semaphore establishes the ordering, so the unchecked conformance is
    /// safe: the write happens-before the signal, the read after the wait.
    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    /// Default tick interval for `blockingRun`'s cancel poll: how often Cancel
    /// gets a chance to cut the wait short.
    static let defaultCancelPollInterval: TimeInterval = 0.25

    /// Runs `operation` to completion, blocking the *calling* thread until it
    /// finishes, polling `shouldCancel` every `tickInterval` while it waits
    /// and cancelling the bridged `Task` the moment the flag trips. Returns
    /// whatever error `operation` threw (a cancelled operation that respects
    /// `Task.isCancelled` surfaces as `CancellationError`), or nil.
    ///
    /// Bridging async → blocking with a semaphore mirrors
    /// `LibraryEncryptionMigrator.materializeIfNeeded`, and is safe for the
    /// same reason: it only ever blocks the dedicated calling thread (the
    /// export thread, here), never a Swift concurrency cooperative-pool
    /// thread. See the "grey-spinner cooperative-pool-starvation" bug class
    /// for what goes wrong when that invariant slips.
    static func blockingRun(
        tickInterval: TimeInterval = LibraryExporter.defaultCancelPollInterval,
        shouldCancel: @escaping () -> Bool,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        let task = Task {
            do {
                try await operation()
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + tickInterval) == .timedOut {
            if shouldCancel() { task.cancel() }
        }
        return box.error
    }

    /// Blocks the calling (dedicated) thread until `url` is materialized.
    /// Cancel responds in roughly a tick interval plus whatever poll
    /// granularity `LibraryFileMaterializer.download` is mid-sleep on when
    /// cancellation lands — around the tick interval, usually well under a
    /// second — rather than waiting out the materializer's 2-minute ceiling.
    /// See `blockingRun` for the blocking bridge itself.
    static func makeBlockingMaterializer(
        shouldCancel: @escaping () -> Bool
    ) -> (URL) -> Error? {
        { url in
            blockingRun(shouldCancel: shouldCancel) {
                if await LibraryFileMaterializer.isReady(url: url) == false {
                    try await LibraryFileMaterializer.download(url: url)
                }
            }
        }
    }

    /// Fire-and-forget: asks iCloud to start pulling a file the write cursor
    /// hasn't reached yet, and returns immediately.
    static func kickDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
