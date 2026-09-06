import Foundation

/// One index row reduced to just what sizing an export needs. Taken from the
/// SwiftData index rather than the container so the confirmation dialog can be
/// built without touching a single file — a full container walk over an
/// evicted library would mean thousands of iCloud round-trips before the user
/// has even agreed to the export.
struct LibraryExportSizingRow: Equatable, Sendable {
    let itemID: Int
    /// `"<id>.jpeg"` / `"<id>.mp4"`, exactly as it appears in the container.
    let mediaFileName: String
    let fileByteSize: Int
    /// True when the media is not currently materialized locally.
    let isEvicted: Bool
}

struct LibraryExportPlan: Equatable {
    /// Estimated from the SwiftData index, NOT from the container. The index
    /// is a disposable cache that can be empty, stale or mid-rebuild, so this
    /// is a hint for the confirmation dialog only — the run itself always
    /// walks the container. Never gate the ability to export on it.
    let itemsToExport: Int
    let alreadyExported: Int
    /// Bytes that must come down from iCloud — the evicted subset.
    let bytesToDownload: Int
    /// Bytes that will land on the destination volume — ALL items still to
    /// export, materialized or not. This, not `bytesToDownload`, is what the
    /// free-space check compares against.
    let bytesToWrite: Int
    /// Free space on the destination volume, or nil when the volume reported
    /// neither capacity key (see `LibraryExportPlanner.availableCapacity`).
    let availableBytes: Int?

    /// Everything the index knows about, exported or not — the figure the
    /// engine's container walk is checked against for a shortfall.
    var indexedItems: Int { itemsToExport + alreadyExported }

    /// Nil capacity is NOT "fits": it is unknown, and the caller reports it as
    /// such (`LibraryExportError.capacityUnknown`) rather than as a full disk.
    var fitsOnDisk: Bool {
        guard let availableBytes else { return false }
        return bytesToWrite <= availableBytes
    }

    var capacityUnknown: Bool { availableBytes == nil }
}

enum LibraryExportPlanner {
    static func plan(
        destination: URL,
        rows: [LibraryExportSizingRow],
        availableBytes: Int?,
        fileManager: FileManager = .default
    ) -> LibraryExportPlan {
        let existing = Set(
            (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? [])

        var itemsToExport = 0
        var alreadyExported = 0
        var bytesToDownload = 0
        var bytesToWrite = 0

        for row in rows {
            let done = existing.contains(row.mediaFileName)
                && existing.contains("\(row.itemID).json")
            if done {
                alreadyExported += 1
                continue
            }
            itemsToExport += 1
            bytesToWrite += row.fileByteSize
            if row.isEvicted { bytesToDownload += row.fileByteSize }
        }

        return LibraryExportPlan(
            itemsToExport: itemsToExport,
            alreadyExported: alreadyExported,
            bytesToDownload: bytesToDownload,
            bytesToWrite: bytesToWrite,
            availableBytes: availableBytes)
    }

    /// Free space on the destination's volume, or nil when the volume reports
    /// neither capacity key.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is the better figure — it
    /// accounts for purgeable space — but it is APFS/HFS+-oriented and returns
    /// nil, or answers a bare `0`, on exactly the volumes a backup is most
    /// likely to target: exFAT USB drives, SMB/NAS mounts. Reading only that
    /// key (and only falling back on nil) made the free-space check refuse
    /// "only Zero bytes is available" on a 4 TB drive whose important-usage
    /// figure came back 0 rather than nil, so a zero answer is treated the
    /// same as no answer and falls through to the plain
    /// `volumeAvailableCapacity` before giving up. Plain available capacity is
    /// never larger than the important-usage figure, so preferring it in the
    /// zero case can only ever under-promise space, never over-promise it.
    ///
    /// Returning nil (rather than 0) keeps "couldn't measure" distinguishable
    /// from "measured, and it's full": the caller reports the two differently.
    ///
    /// `readCapacities` is injected so tests can simulate the exFAT/SMB shape
    /// (important-usage 0 or nil, plain positive) without a real volume of
    /// that kind on hand — a temp directory is always APFS, where the primary
    /// key answers a positive number and the fallback path never runs. It
    /// defaults to the real `URL.resourceValues` read of both keys.
    static func availableCapacity(
        at url: URL,
        readCapacities: (URL) -> (important: Int64?, plain: Int?) =
            LibraryExportPlanner.readVolumeCapacities
    ) -> Int? {
        let (important, plain) = readCapacities(url)
        if let important, important > 0 {
            return Int(important)
        }
        return plain
    }

    /// The real key lookup `availableCapacity(at:)` defaults to. Split out
    /// purely so it can be swapped for a stub in tests.
    private static func readVolumeCapacities(_ url: URL) -> (important: Int64?, plain: Int?) {
        let important = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        let plain = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityKey]
        ).volumeAvailableCapacity
        return (important, plain)
    }
}
