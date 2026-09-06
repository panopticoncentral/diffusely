import Foundation

/// One item (or one container file) that did not export cleanly. Collected and
/// reported; never fatal to the run — see `LibraryExporter`.
struct LibraryExportFailure: Equatable {
    enum Reason: Equatable {
        /// The sidecar could not be read or decrypted.
        case sidecarUnreadable
        /// The sidecar was read but is not a decodable `LibraryItemMetadata`.
        case sidecarUndecodable
        /// The media file is absent, or unreadable after materialization.
        case mediaMissing
        /// iCloud materialization errored or timed out.
        case downloadFailed(String)
        /// SHA-256 of the media bytes disagreed with the sidecar's
        /// `contentSHA256`. The file IS still exported — the container's copy
        /// may be the only other copy, so refusing to back it up would turn
        /// one suspect copy into one suspect copy and no backup.
        case integrityMismatch
        /// An album file in the container could not be read or decrypted.
        /// Deliberately distinct from a *decode* failure on an encrypted aux
        /// file, which is not a failure at all but the classification path
        /// that separates album files from sort-assistant state in the shared
        /// opaque `.x` namespace — see `LibraryExporter.albumPayloads`.
        case albumUnreadable
        case writeFailed(String)
    }

    /// Nil when the sidecar couldn't be decoded far enough to learn the id.
    let itemID: Int?
    /// The container file name, so an unidentifiable failure is still traceable.
    let fileName: String
    let reason: Reason
}

/// Outcome of one export run.
struct LibraryExportSummary: Equatable {
    var exported = 0
    var skipped = 0
    var albumsExported = 0
    var bytesWritten = 0
    var cancelled = false
    var failures: [LibraryExportFailure] = []

    /// Item sidecars the container walk actually found — the run's real
    /// denominator. Enumeration is best-effort by construction
    /// (`LibraryFileStore.enumerateMetadataFiles()` swallows a throwing
    /// `contentsOfDirectory` and returns `[]`), and the directory it walks can
    /// be an evicted iCloud container or, pre-bootstrap, an empty scratch
    /// fallback. Recording it is what lets a short or empty walk be told apart
    /// from a genuinely small Library instead of both reporting "complete".
    var enumeratedItems = 0
    /// How many items the SwiftData index expected the container to hold,
    /// carried in from the pre-flight plan. Zero means "no estimate available"
    /// (empty, stale or rebuild-pending index), never "zero items".
    var indexedItems = 0

    /// Items the index expected that the container walk never saw. The alarm
    /// case: an evicted/unresolved/short enumeration silently exporting a
    /// fraction of the Library.
    var indexShortfall: Int { max(0, indexedItems - enumeratedItems) }

    /// Items on disk the index didn't know about — the spec's "6 items on disk
    /// weren't in the index". Informational: the container is the source of
    /// truth, so these are exported anyway.
    var indexSurplus: Int { indexedItems == 0 ? 0 : max(0, enumeratedItems - indexedItems) }

    /// True when this run must NOT be presented as an unqualified success:
    /// the walk found nothing at all, or found materially fewer files than the
    /// index expected. Deliberately trips on ANY shortfall rather than some
    /// tolerance band — for a backup there is no size of silent hole that is
    /// acceptable, and the alternative (a threshold) is a band in which a
    /// partial archive reports "Export Complete".
    var isPotentiallyIncomplete: Bool { enumeratedItems == 0 || indexShortfall > 0 }

    init() {}
}

/// Setup-level refusals. These abort before anything is written and are the
/// only errors that surface as a failed export; per-item problems become
/// `LibraryExportFailure` values instead.
enum LibraryExportError: LocalizedError, Equatable {
    case vaultLocked
    /// The container is unlocked but half-encrypted (a partial or failed
    /// encryption enable). Checked here as well as in the UI's `libraryGate`
    /// because an export against that store would enumerate only one of the
    /// two naming conventions and silently omit the other half.
    case setupIncomplete
    case destinationInsideContainer
    case destinationNotWritable(String)
    case insufficientSpace(needed: Int, available: Int)
    /// Neither volume-capacity key could be read for the destination volume,
    /// so free space is unknown. Reported distinctly rather than as
    /// `insufficientSpace(available: 0)`, which claimed a 4 TB drive was full.
    case capacityUnknown(needed: Int, path: String)

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "Unlock the Library before exporting."
        case .setupIncomplete:
            // One literal rather than a `+` chain, defensively: the exact
            // shape (a `+` chain of string literals with interpolations) is
            // what made SourceKit fail to type-check LibraryExportSheet.swift
            // elsewhere in this feature, once one interpolation there was a
            // generic `Int.formatted()` call. This case has no interpolation
            // at all, so there's nothing left for `+` to buy over one literal.
            return "The Library is still finishing its encryption setup. Finish (or undo) that in Settings before exporting — until it's done, part of the Library would be left out of the archive."
        case .destinationInsideContainer:
            return "Choose a folder outside the Library's iCloud container. "
                 + "Exporting into it would make the app treat the export as new items, "
                 + "and would upload a decrypted copy of the Library back to iCloud."
        case .destinationNotWritable(let path):
            return "Can't write to \(path)."
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "This export needs about \(f.string(fromByteCount: Int64(needed))), "
                 + "but only \(f.string(fromByteCount: Int64(available))) is available."
        case .capacityUnknown(let needed, let path):
            // Same defensive simplification as `.setupIncomplete` above: the
            // `+`-chain-with-interpolation shape is what made SourceKit fail
            // to type-check LibraryExportSheet.swift, so it gets flattened
            // here too rather than left as a second instance of the pattern.
            let f = ByteCountFormatter()
            let neededText = f.string(fromByteCount: Int64(needed))
            return "Couldn't determine how much free space is available on the volume holding \(path), so this export can't be started safely. It needs about \(neededText). Try a folder on another volume."
        }
    }
}

enum LibraryExportDestination {
    /// The directory an export must stay out of, derived from the Library's
    /// items directory.
    ///
    /// Guarding `Items/` alone is not enough. It avoids the app-scans-its-own-
    /// export hazard, but `<ubiquityRoot>/Documents/Backup` is a *sibling* of
    /// `Items/` and passes that check — so a full plaintext, decrypted copy of
    /// an at-rest-encrypted Library would be written into the same iCloud
    /// container and uploaded. That is the same security reasoning that makes
    /// "never export `vault.json`" a rule, and it also sits directly beside
    /// `vault.json` itself, which lives in `Documents/`.
    ///
    /// The two layouts `LibraryContainer.itemsDirectory()` can produce are
    /// recognised structurally:
    /// - iCloud: `<ubiquityRoot>/Documents/Items` → the whole ubiquity
    ///   container root is protected.
    /// - Local fallback: `<Application Support>/Library/Items` → the app's
    ///   `Library` folder (which also holds `vault.json`) is protected. Its
    ///   parent, all of Application Support, deliberately is NOT: that would
    ///   be a guard over other apps' data, far wider than this feature's
    ///   business.
    /// Anything that matches neither layout (tests, future layouts) protects
    /// exactly the directory it was given. The widening is deliberately
    /// limited to the two shapes `LibraryContainer` actually produces rather
    /// than applied to any directory that happens to be called `Items` —
    /// guarding a whole parent tree on the strength of one folder name would
    /// refuse destinations that have nothing to do with the Library.
    static func protectedRoot(forItemsDirectory itemsDirectory: URL) -> URL {
        guard itemsDirectory.lastPathComponent == "Items" else { return itemsDirectory }
        let parent = itemsDirectory.deletingLastPathComponent()
        switch parent.lastPathComponent {
        // `<ubiquityRoot>/Documents/Items` — climb past `Documents` to the
        // container root, so siblings of `Documents` are covered too.
        case "Documents": return parent.deletingLastPathComponent()
        // `<Application Support>/Library/Items` — the app's own Library
        // folder, which also holds `vault.json`.
        case "Library": return parent
        default: return itemsDirectory
        }
    }

    /// Rejects a destination that overlaps the Library's protected root in
    /// either direction, or that we can't write to.
    static func validate(
        destination: URL,
        itemsDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        if overlaps(destination, protectedRoot(forItemsDirectory: itemsDirectory)) {
            throw LibraryExportError.destinationInsideContainer
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: destination.path) else {
            throw LibraryExportError.destinationNotWritable(destination.path)
        }
    }

    /// Non-throwing form for callers that hop this (blocking) check onto a
    /// dedicated queue, where a `Result`/`rethrows` dance buys nothing.
    static func validateForExport(
        destination: URL,
        itemsDirectory: URL,
        fileManager: FileManager = .default
    ) -> LibraryExportError? {
        do {
            try validate(destination: destination, itemsDirectory: itemsDirectory,
                         fileManager: fileManager)
            return nil
        } catch let error as LibraryExportError {
            return error
        } catch {
            return .destinationNotWritable(destination.path)
        }
    }

    /// True when either path is the other, or contains the other. Compared on
    /// standardized paths with a trailing separator so `/x/Items2` is not read
    /// as living inside `/x/Items`.
    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let pathA = normalized(a)
        let pathB = normalized(b)
        return pathA == pathB || pathA.hasPrefix(pathB) || pathB.hasPrefix(pathA)
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
