#if os(macOS)
import SwiftUI

/// Confirm → progress → summary for one Library export. Owns the service (one
/// instance per presentation), mirroring `SortAssistantSheet`.
struct LibraryExportSheet: View {
    let destination: URL
    let indexService: LibraryIndexService

    @Environment(\.dismiss) private var dismiss
    @StateObject private var service: LibraryExportService

    init(destination: URL, indexService: LibraryIndexService) {
        self.destination = destination
        self.indexService = indexService
        _service = StateObject(wrappedValue: .live(indexService: indexService))
    }

    /// Both phases that own live background work. `.preparing` counts because
    /// the pre-flight is no longer trivial — it lists the destination folder
    /// (thousands of names when re-running into an existing archive), scans a
    /// possibly half-encrypted container and probes the destination volume,
    /// all on the export queue.
    private var isRunning: Bool {
        switch service.phase {
        case .exporting, .preparing: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            content
        }
        .padding(28)
        // macOS sheets size to their content's IDEAL height, so pin a width
        // and let the content breathe — see SortAssistantSheet's note.
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 560)
        // `.preparing` and `.exporting` both count as running, so neither can
        // be dismissed out from under its background work by an accidental
        // click-through. Each offers an explicit Cancel instead, and
        // `prepare()` now honours the cancel flag between its queue hops, so
        // `onDisappear`'s `cancel()` genuinely stops a slow pre-flight rather
        // than leaking it.
        .interactiveDismissDisabled(isRunning)
        .onDisappear { service.cancel() }
        .task { await service.prepare(destination: destination) }
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle, .preparing:
            VStack(spacing: 16) {
                ProgressView("Preparing…")
                Button("Cancel") {
                    service.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 16)

        case .confirming(let plan):
            confirmation(plan)

        case .exporting(let done, let total):
            VStack(spacing: 12) {
                Text("Exporting Library").font(.headline)
                if let total {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done.formatted()) of \(total.formatted())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // The engine hasn't reported its container walk yet, so
                    // there is no honest denominator to draw a bar against.
                    ProgressView()
                    Text("Scanning the Library…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { service.cancel() }
                    .buttonStyle(.bordered)
            }

        case .finished(let summary):
            summaryView(summary)

        case .failed(let message):
            VStack(spacing: 16) {
                ContentUnavailableView("Can't Export",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func confirmation(_ plan: LibraryExportPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Library").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                // Every figure here is an ESTIMATE from the SwiftData index,
                // which can be empty, stale or mid-rebuild. The run itself
                // walks the container, so the wording never promises an exact
                // count and the button is never gated on one.
                if plan.itemsToExport > 0 {
                    Text("Export about **\(plan.itemsToExport.formatted())** items to **\(destination.lastPathComponent)**.")
                } else {
                    Text("Export the Library to **\(destination.lastPathComponent)**.")
                }
                if plan.bytesToDownload > 0 {
                    Text("About \(byteText(plan.bytesToDownload)) needs downloading from iCloud first.")
                        .foregroundStyle(.secondary)
                }
                if plan.alreadyExported > 0 {
                    Text("About \(plan.alreadyExported.formatted()) items are already exported and will be skipped.")
                        .foregroundStyle(.secondary)
                }
                if let available = plan.availableBytes {
                    Text("\(byteText(available)) available on the destination volume.")
                        .foregroundStyle(.secondary)
                }
                Text(plan.indexedItems == 0
                     ? "The Library index has no entries to estimate from — the export still copies everything found in the Library folder."
                     : "Counts are estimated from the Library index; the export always copies everything found in the Library folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                // Deliberately never disabled on the index's count: an empty,
                // stale or rebuild-pending index would otherwise make the
                // export unreachable, and after one complete run a second run
                // (to pick up album files or items added since) could never be
                // started at all.
                Button("Export") { service.start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summaryView(_ summary: LibraryExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headline(for: summary))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                // The completeness warning comes FIRST: a run that walked
                // fewer container files than the index expected (an evicted or
                // unresolved container, a directory listing that failed and
                // was swallowed into an empty list) must never read as an
                // unqualified success, which for a backup is the worst
                // possible outcome.
                if let warning = incompletenessWarning(for: summary) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("\(summary.exported.formatted()) items exported (\(byteText(summary.bytesWritten))).")
                if summary.skipped > 0 {
                    Text("\(summary.skipped.formatted()) already present, skipped.")
                        .foregroundStyle(.secondary)
                }
                if summary.albumsExported > 0 {
                    Text("\(summary.albumsExported.formatted()) album files exported.")
                        .foregroundStyle(.secondary)
                }
                if !summary.failures.isEmpty {
                    Text("\(summary.failures.count.formatted()) items failed — see \(LibraryExporter.failuresFileName) in the folder.")
                        .foregroundStyle(.orange)
                }
                if summary.indexSurplus > 0 {
                    // The spec's other direction: the container is truth, so
                    // these were exported — worth saying, not worth alarm.
                    Text("\(summary.indexSurplus.formatted()) items on disk weren't in the Library index; they were exported too.")
                        .foregroundStyle(.secondary)
                }
                if summary.cancelled {
                    Text("Run the export again to finish; completed items are skipped.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func headline(for summary: LibraryExportSummary) -> String {
        if summary.cancelled { return "Export Cancelled" }
        return summary.isPotentiallyIncomplete ? "Export May Be Incomplete" : "Export Complete"
    }

    /// The C1 guard, in words. Two shapes, both deliberately unqualified about
    /// what the user should do next, because in every case the remedy is the
    /// same: get the Library fully loaded and run it again (a re-run skips
    /// what already landed).
    private func incompletenessWarning(for summary: LibraryExportSummary) -> String? {
        if summary.enumeratedItems == 0 {
            return "No Library files were found to export. If the Library isn't empty, "
                 + "wait for it to finish loading (and check that iCloud is signed in), "
                 + "then export again."
        }
        // Any shortfall at all is surfaced. A tolerance band would be a range
        // in which a partial archive still claims to be complete, and for a
        // backup there is no acceptable size of silent hole.
        guard summary.indexShortfall > 0 else { return nil }
        // Hoisted into plain-`String` lets before building the sentence:
        // interpolating `Int.formatted()` (generic over `FormatStyle`)
        // directly into a multi-term `+` chain made SourceKit fail to
        // type-check this file ("unable to type-check this expression in
        // reasonable time"); a single literal over concrete `String` values
        // has nothing left for the constraint solver to search.
        let indexedText = summary.indexedItems.formatted()
        let enumeratedText = summary.enumeratedItems.formatted()
        let shortfallText = summary.indexShortfall.formatted()
        return "The Library index lists \(indexedText) items but only "
             + "\(enumeratedText) were found in the Library folder, so this "
             + "archive may be missing \(shortfallText). "
             + "Wait for the Library to finish loading and export again — anything "
             + "already exported is skipped. If this keeps happening, the index "
             + "may simply be stale after deletions."
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
