import SwiftUI

/// Sort Assistant flow: classify unsorted Library items with an LLM, then
/// review suggestions grouped by album. Presented from the Library's Albums
/// mode. Owns the service (one instance per presentation); the inner flow
/// view observes it.
struct SortAssistantSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var openRouterConfig = OpenRouterConfig.shared
    @State private var service: SortAssistantService?

    var body: some View {
        NavigationStack {
            Group {
                if !openRouterConfig.hasAPIKey {
                    ContentUnavailableView(
                        "OpenRouter Key Needed",
                        systemImage: "key",
                        description: Text("Add your OpenRouter API key in Settings to use the Sort Assistant."))
                } else if let service {
                    SortAssistantFlowView(service: service)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Sort Assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Suggestions are applied as they're accepted, so Done is the
                // confirming action (bold, trailing) rather than a cancel.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        service?.cancel()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        // macOS sheets size to their content's IDEAL height, and the profile
        // confirmation Form (one section per album) can report a height taller
        // than the screen — pushing the toolbar and Continue button off-screen.
        // Pin an explicit ideal size so the sheet stays bounded and the content
        // scrolls inside it instead.
        .frame(minWidth: 540, idealWidth: 1000, maxWidth: 1400,
               minHeight: 480, idealHeight: 850, maxHeight: 1000)
        #endif
        .interactiveDismissDisabled()
        .onDisappear {
            // Safety net for dismissal paths that skip the Done button (Esc on
            // macOS, window close): stop any in-flight classification so a
            // dismissed sheet can't keep spending API calls in the background.
            service?.cancel()
        }
        .task {
            guard service == nil, openRouterConfig.hasAPIKey else { return }
            guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
            let classifier = OpenRouterClassifier(
                apiKey: openRouterConfig.apiKey ?? "",
                model: openRouterConfig.model)
            let svc = SortAssistantService(
                albumService: store.albumService,
                classifier: classifier,
                itemsDirectory: dir)
            service = svc
            svc.start()
        }
    }
}

/// Observes the service and renders the current phase.
private struct SortAssistantFlowView: View {
    @ObservedObject var service: SortAssistantService

    var body: some View {
        switch service.phase {
        case .idle, .scanning:
            ProgressView("Scanning library…")
        case .buildingProfiles(let done, let total):
            progress("Building album profiles…", done: done, total: total)
        case .profilesReady:
            profileConfirmation
        case .classifying(let done, let total):
            VStack(spacing: 16) {
                progress("Classifying prompts…", done: done, total: total)
                Button("Stop and review what's done") { service.cancel() }
                    .buttonStyle(.bordered)
            }
        case .failed(let message):
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Sort Failed", systemImage: "exclamationmark.triangle",
                    description: Text(message))
                Button("Retry") { service.start() }
                    .buttonStyle(.borderedProminent)
            }
        case .review:
            reviewList
        }
    }

    private func progress(_ label: String, done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(maxWidth: 280)
            Text("\(label) \(done)/\(total)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    /// Built profiles, editable before classification starts.
    private var profileConfirmation: some View {
        Form {
            Section {
                Text("The assistant summarized what each album contains, based on the prompts of items you've already filed. Edit anything that's off — these descriptions steer the sorting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach($service.builtProfiles) { $profile in
                Section(profile.name) {
                    TextEditor(text: $profile.text)
                        .frame(minHeight: 80)
                }
            }
            Section {
                Button("Continue") { service.beginClassification() }
                    .frame(maxWidth: .infinity)
            }
        }
        // The default macOS form style doesn't scroll; grouped matches the
        // iOS appearance and scrolls when the sheet bounds the height.
        .formStyle(.grouped)
        .toolbar {
            // Always-visible Continue: with many albums the in-form button
            // sits below the fold, so mirror it in the toolbar.
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") { service.beginClassification() }
            }
        }
    }

    private var reviewList: some View {
        List {
            if service.failedBatchCount > 0 {
                Section {
                    Label("\(service.failedBatchCount) request batch(es) failed — re-run later to cover those items.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if service.groups.isEmpty {
                ContentUnavailableView(
                    "All Reviewed", systemImage: "checkmark.circle",
                    description: Text("No suggestions left to review."))
            } else {
                Section("Suggestions") {
                    ForEach(service.groups) { group in
                        NavigationLink {
                            SortReviewGroupView(group: group, service: service)
                        } label: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text("\(group.entries.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
