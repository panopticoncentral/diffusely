import Foundation

/// Read-only diagnostic for the "Other" / "Videos" buckets in the
/// checkpoint-grouped Library.
///
/// `groupByCheckpoint` puts an item in a named group only when its index row
/// carries a `checkpointName`, which is denormalized in exactly one way (see
/// `PersistedLibraryItem.init(metadata:downloadStatus:)` and the mirror in
/// `LibraryIndexService.apply`): the FIRST sidecar resource whose `modelType`
/// is exactly `"Checkpoint"`. Everything else falls into "Videos" (video) or
/// "Other" (image).
///
/// A nil `checkpointName` therefore has several very different causes that the
/// UI collapses into one bucket, and they call for opposite fixes:
///
/// * `.noGenerationData` — the sidecar has no generation data at all. Either
///   the save-time fetch failed (it is called with `try?` in
///   `LibrarySaveService`, so a failure is silent and permanent) or Civitai
///   had none. Fixable by a re-fetch backfill.
/// * `.noResources` / `.noCheckpointResource` — Civitai returned generation
///   data but never hash-matched a base model. Typical of ComfyUI and
///   off-site uploads, where the base model is a raw file that isn't a
///   Civitai model. A re-fetch may or may not help; Civitai matches
///   resources retroactively.
/// * `.checkpointNameBlank` — the resource is there but unnamed. A re-fetch
///   won't help; only display would.
///
/// This type answers which of those applies, across the whole container, and
/// cross-checks the index against it.
///
/// Note on what the container can and cannot tell us: sidecars store the
/// *re-encoded* `GenerationData` (`type` / `meta` / `resources` only), so
/// Civitai's `process`, `onSite`, and the raw `meta.Model` filename are not
/// on disk. Distinguishing "Civitai never had a checkpoint" from "we lost it
/// at save time" needs a network probe; this report gives you the sample ids
/// to probe.
enum LibraryCheckpointDiagnostics {

    // MARK: - Classification

    /// Why one sidecar does or doesn't yield a checkpoint name.
    enum Kind: String, CaseIterable, Sendable {
        case hasCheckpoint
        case checkpointNameBlank
        case noCheckpointResource
        case noResources
        case noGenerationData

        var label: String {
            switch self {
            case .hasCheckpoint:         return "Grouped under a checkpoint"
            case .checkpointNameBlank:   return "Checkpoint resource with a blank name"
            case .noCheckpointResource:  return "Resources present, none typed \"Checkpoint\""
            case .noResources:           return "Generation data present, zero resources"
            case .noGenerationData:      return "No generation data in the sidecar"
            }
        }
    }

    struct Finding: Sendable {
        let itemID: Int
        let mediaType: LibraryMediaType
        let savedAt: Date
        let kind: Kind
        /// The name the index *should* hold, derived exactly as the real
        /// denormalization does. Nil for every kind but `.hasCheckpoint`.
        let checkpointName: String?
        /// Distinct `modelType`s on the sidecar's resources, sorted. Shows at a
        /// glance whether Civitai matched only LoRAs, or used a casing we
        /// don't match on.
        let resourceTypes: [String]

        /// True when this item lands in "Videos" or "Other" rather than a
        /// named checkpoint group.
        var isUngrouped: Bool { kind != .hasCheckpoint }
    }

    /// Pure classifier. Its `checkpointName` is contractually identical to
    /// `PersistedLibraryItem.checkpointName` for the same metadata — the test
    /// suite pins that, because a diagnostic that derives the value even
    /// slightly differently would explain the wrong bug.
    static func classify(_ metadata: LibraryItemMetadata) -> Finding {
        let base = { (kind: Kind, name: String?, types: [String]) in
            Finding(itemID: metadata.itemID, mediaType: metadata.mediaType,
                    savedAt: metadata.savedAt, kind: kind,
                    checkpointName: name, resourceTypes: types)
        }

        guard let generationData = metadata.generationData else {
            return base(.noGenerationData, nil, [])
        }
        guard let resources = generationData.resources, !resources.isEmpty else {
            return base(.noResources, nil, [])
        }

        let types = Set(resources.compactMap(\.modelType)).sorted()
        // Same predicate as the denormalization: exact "Checkpoint", first match.
        guard let checkpoint = resources.first(where: { $0.modelType == "Checkpoint" }) else {
            return base(.noCheckpointResource, nil, types)
        }
        guard let name = checkpoint.modelName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base(.checkpointNameBlank, nil, types)
        }
        return base(.hasCheckpoint, name, types)
    }

    // MARK: - Report

    struct DayCount: Equatable, Sendable {
        let total: Int
        let ungrouped: Int
    }

    /// An index row that exists but disagrees with its sidecar. Deliberately
    /// excludes sidecars with no row at all: the container is scanned before
    /// the index is read, so anything iCloud delivers mid-scan legitimately
    /// has no row yet, and folding that in reported 15 perfectly healthy
    /// items as drift on a real run. Those go to `notYetIndexed` instead.
    struct Disagreement: Sendable {
        enum Kind: Sendable, Equatable {
            /// Row present, holds no name, sidecar derives one. A rebuild fixes it.
            case nameMissing
            /// Row present and holds a different name than the sidecar derives
            /// (including a stale name over a sidecar that now derives none).
            case nameDiffers
        }
        let itemID: Int
        let kind: Kind
        let sidecar: String?
        let index: String?
    }

    struct Report: Sendable {
        let findings: [Finding]
        /// Real drift only — every entry has a row in the index.
        let indexDisagreements: [Disagreement]
        /// Sidecars the index has no row for. Normally transient: the scan
        /// races container inflow, and reconcile ingests these moments later.
        let notYetIndexed: [Int]
        /// UTC day (`yyyy-MM-dd`) → totals, over every scanned sidecar.
        let saveDayHistogram: [String: DayCount]
        /// `modelType` → number of ungrouped items carrying it.
        let resourceTypeHistogram: [String: Int]
        let isEncryptedContainer: Bool?
        /// Sidecars present but unreadable during the scan — an iCloud
        /// placeholder or a torn write, not a checkpoint problem. Surfaced so
        /// a partial scan can't be mistaken for a complete one.
        let unreadableCount: Int

        var total: Int { findings.count }
        func count(of kind: Kind) -> Int { findings.count { $0.kind == kind } }

        /// The two buckets `groupByCheckpoint` actually renders.
        var otherBucketCount: Int {
            findings.count { $0.isUngrouped && $0.mediaType != .video }
        }
        var videosBucketCount: Int {
            findings.count { $0.isUngrouped && $0.mediaType == .video }
        }
        var ungroupedCount: Int { findings.count(where: \.isUngrouped) }

        /// Up to `limit` item ids for a kind, so you can probe them against
        /// `image.getGenerationData` and see whether Civitai has a checkpoint
        /// today that the sidecar lacks.
        func sampleIDs(of kind: Kind, limit: Int = 25) -> [Int] {
            findings.lazy.filter { $0.kind == kind }.prefix(limit).map(\.itemID)
        }

        var text: String { renderReport(self) }
    }

    /// - Parameters:
    ///   - indexCheckpointNames: `itemID` → name, for rows that have one.
    ///   - indexedItemIDs: EVERY id the index holds a row for. Required, and
    ///     separate from the names, because "row absent" and "row present with
    ///     no name" are different diagnoses that the names map alone cannot
    ///     tell apart — only the second is drift.
    static func report(
        findings: [Finding],
        indexCheckpointNames: [Int: String],
        indexedItemIDs: Set<Int>,
        isEncryptedContainer: Bool? = nil,
        unreadableCount: Int = 0
    ) -> Report {
        var disagreements: [Disagreement] = []
        var notYetIndexed: [Int] = []
        var days: [String: (total: Int, ungrouped: Int)] = [:]
        var types: [String: Int] = [:]

        for finding in findings {
            let sidecar = normalized(finding.checkpointName)
            let index = normalized(indexCheckpointNames[finding.itemID])
            if !indexedItemIDs.contains(finding.itemID) {
                notYetIndexed.append(finding.itemID)
            } else if sidecar != index {
                disagreements.append(Disagreement(
                    itemID: finding.itemID,
                    kind: index == nil ? .nameMissing : .nameDiffers,
                    sidecar: sidecar,
                    index: index
                ))
            }

            let day = utcDayFormatter.string(from: finding.savedAt)
            var counts = days[day] ?? (0, 0)
            counts.total += 1
            if finding.isUngrouped { counts.ungrouped += 1 }
            days[day] = counts

            if finding.isUngrouped {
                for type in finding.resourceTypes { types[type, default: 0] += 1 }
            }
        }

        return Report(
            findings: findings,
            indexDisagreements: disagreements,
            notYetIndexed: notYetIndexed,
            saveDayHistogram: days.mapValues { DayCount(total: $0.total, ungrouped: $0.ungrouped) },
            resourceTypeHistogram: types,
            isEncryptedContainer: isEncryptedContainer,
            unreadableCount: unreadableCount
        )
    }

    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Rendering

    private static func renderReport(_ report: Report) -> String {
        var lines: [String] = []
        func row(_ label: String, _ value: Int) {
            lines.append("  \(label.padding(toLength: max(46, label.count + 2), withPad: " ", startingAt: 0))\(value)")
        }

        lines.append("Library checkpoint diagnostic — \(report.total) sidecars scanned")
        if let encrypted = report.isEncryptedContainer {
            lines.append("Container: \(encrypted ? "encrypted" : "plaintext")")
        }
        if report.unreadableCount > 0 {
            lines.append("\(report.unreadableCount) sidecar(s) were present but unreadable (placeholder or torn write) and are NOT classified below.")
        }
        lines.append("")

        lines.append("Grouping outcome")
        row("Grouped under a checkpoint", report.count(of: .hasCheckpoint))
        row("\"Other\" bucket (images)", report.otherBucketCount)
        row("\"Videos\" bucket (videos)", report.videosBucketCount)
        lines.append("")

        lines.append("Classification of all \(report.total) sidecars")
        for kind in Kind.allCases { row(kind.label, report.count(of: kind)) }
        lines.append("")

        lines.append("Index vs container")
        row("Rows disagreeing with their sidecar", report.indexDisagreements.count)
        for disagreement in report.indexDisagreements.prefix(25) {
            let kind = disagreement.kind == .nameMissing ? "no name" : "differs"
            lines.append("    \(disagreement.itemID) [\(kind)]: sidecar=\(disagreement.sidecar ?? "—") index=\(disagreement.index ?? "—")")
        }
        if report.indexDisagreements.count > 25 {
            lines.append("    …and \(report.indexDisagreements.count - 25) more")
        }
        row("Sidecars not yet in the index", report.notYetIndexed.count)
        if !report.notYetIndexed.isEmpty {
            lines.append("    \(report.notYetIndexed.prefix(25).map(String.init).joined(separator: ", "))")
            lines.append("    Normally transient — the container is scanned before the index is")
            lines.append("    read, so items arriving over iCloud mid-scan land here and are")
            lines.append("    ingested by the next reconcile. Only a count that persists across")
            lines.append("    runs is a problem.")
        }
        lines.append("")

        if !report.resourceTypeHistogram.isEmpty {
            lines.append("Resource types on ungrouped items")
            for (type, count) in report.resourceTypeHistogram.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                row(type, count)
            }
            lines.append("")
        }

        // A day that is entirely ungrouped points at a save-time fetch-failure
        // window; a steady low rate points at content Civitai has no
        // checkpoint for. Only days with at least one ungrouped item are worth
        // listing.
        let interestingDays = report.saveDayHistogram.filter { $0.value.ungrouped > 0 }.sorted { $0.key < $1.key }
        if !interestingDays.isEmpty {
            lines.append("Ungrouped by save day (UTC) — ungrouped/total")
            for (day, counts) in interestingDays {
                let share = counts.total > 0 ? Int((Double(counts.ungrouped) / Double(counts.total) * 100).rounded()) : 0
                lines.append("  \(day): \(counts.ungrouped)/\(counts.total)  (\(share)%)")
            }
            lines.append("")
        }

        lines.append("Sample ids to probe against image.getGenerationData")
        for kind in Kind.allCases where kind != .hasCheckpoint {
            let ids = report.sampleIDs(of: kind)
            guard !ids.isEmpty else { continue }
            lines.append("  \(kind.label):")
            lines.append("    \(ids.map(String.init).joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Sidecars store only the re-encoded GenerationData (type/meta/resources);")
        lines.append("Civitai's process/onSite and the raw meta.Model filename are not on disk,")
        lines.append("so \"Civitai never matched a checkpoint\" vs \"we lost it at save time\"")
        lines.append("has to be settled by probing the sample ids above.")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Container scan

enum LibraryCheckpointDiagnosticsError: Error, Equatable {
    /// A configured-but-locked vault has no DEK. Scanning anyway would build
    /// a plaintext passthrough over an encrypted container, find no readable
    /// sidecars, and report a library-wide catastrophe that isn't real — the
    /// same hazard `LibraryIndexService.reconcile` guards against.
    case vaultLocked
}

/// Walks every sidecar in the container and classifies it. Vault-aware and
/// off-main by construction, mirroring `FileLibraryBackfillSidecarStore`:
/// the directory walk and per-sidecar decrypt+decode are blocking syscalls
/// that must not run on the caller's actor.
struct LibraryCheckpointDiagnosticsScanner: Sendable {
    let itemsDirectory: URL

    /// Test seam, matching `FileLibraryBackfillSidecarStore`'s: resolves lock
    /// state and crypto from ONE vault snapshot so the two can never disagree.
    var resolveVaultContext: @Sendable () async -> (state: LibraryVault.State, crypto: LibraryFileCrypto?) = {
        let ctx = await LibraryVaultProvider.shared.reconcileContext()
        return (ctx.state, ctx.store.crypto)
    }

    struct ScanResult: Sendable {
        let findings: [LibraryCheckpointDiagnostics.Finding]
        /// Sidecars present but unreadable this pass (placeholder, torn write,
        /// bad bytes). Reported rather than silently folded into a cause.
        let unreadableCount: Int
        let isEncrypted: Bool
    }

    func scan() async throws -> ScanResult {
        let directory = itemsDirectory
        let vault = await resolveVaultContext()
        guard vault.state != .locked else { throw LibraryCheckpointDiagnosticsError.vaultLocked }
        let crypto = vault.crypto

        return await Task.detached(priority: .utility) {
            let store = LibraryFileStore(itemsDirectory: directory, crypto: crypto)
            var findings: [LibraryCheckpointDiagnostics.Finding] = []
            var unreadable = 0
            for url in store.enumerateMetadataFiles() {
                guard
                    let id = store.itemID(forMetadataFile: url),
                    let data = store.readMetadata(itemID: id),
                    let metadata = try? LibraryItemMetadata.decoder()
                        .decode(LibraryItemMetadata.self, from: data)
                else {
                    unreadable += 1
                    continue
                }
                findings.append(LibraryCheckpointDiagnostics.classify(metadata))
            }
            return ScanResult(findings: findings, unreadableCount: unreadable, isEncrypted: store.isEncrypted)
        }.value
    }
}
