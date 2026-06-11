import SwiftUI

/// Edits an album's owner-written description and (when one exists) the
/// AI-built profile the Sort Assistant uses to steer classification. Both
/// fields live on the album file (source of truth) and sync across devices;
/// saves go through `LibraryAlbumService`, which keeps the index in step.
struct AlbumDescriptionSheet: View {
    /// Identity-carrying payload captured at presentation time (mirrors
    /// `LibraryView.AddToAlbumRequest`): `.sheet(item:)` rebuilds the sheet
    /// per presentation so it always reflects the current index row.
    struct Request: Identifiable {
        let id = UUID()
        let albumID: UUID
        let albumName: String
        let userDescription: String?
        let profileText: String?
        let profileBuiltAt: Date?
        let profileMemberCount: Int
    }

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var openRouterConfig = OpenRouterConfig.shared

    let request: Request
    @State private var descriptionText: String
    @State private var profileText: String
    /// Baseline saved alongside the text. Hand-edits keep the request's
    /// original values (a correction, not a rebuild); in-sheet generation
    /// stamps fresh ones. Nil `builtAt` means no profile exists yet.
    @State private var builtAt: Date?
    @State private var memberCount: Int
    @State private var isSaving = false
    @State private var isGenerating = false
    @State private var generationError: String?

    init(request: Request) {
        self.request = request
        _descriptionText = State(initialValue: request.userDescription ?? "")
        _profileText = State(initialValue: request.profileText ?? "")
        _builtAt = State(initialValue: request.profileText != nil
            ? (request.profileBuiltAt ?? Date()) : nil)
        _memberCount = State(initialValue: request.profileMemberCount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...5)
                        // The section header is the label; without this, the
                        // macOS grouped form treats the title as a leading
                        // label and right-justifies the input on the trailing
                        // edge of the row.
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                } header: {
                    Text("Your Description")
                } footer: {
                    Text("Used by the Sort Assistant when deciding what belongs in this album, and as input when it builds the profile below.")
                }

                Section {
                    if builtAt != nil {
                        TextEditor(text: $profileText)
                            .frame(minHeight: 100)
                    } else {
                        Text("No profile yet — generate one below, or let the Sort Assistant build it on its next run from this album's items and your description.")
                            .foregroundStyle(.secondary)
                    }
                    generateRow
                    if let generationError {
                        Text(generationError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("AI Profile")
                } footer: {
                    if let builtAt {
                        Text("Built from \(memberCount) item\(memberCount == 1 ? "" : "s") on \(builtAt.formatted(date: .abbreviated, time: .omitted)). The assistant rebuilds it when the album has doubled in size; your edits steer sorting until then.")
                    } else if !openRouterConfig.hasAPIKey {
                        Text("Generating needs an OpenRouter API key — add one in Settings.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.albumName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
        }
        #if os(macOS)
        // macOS sheets size to ideal content height; keep this one bounded
        // (same lesson as SortAssistantSheet).
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 700,
               minHeight: 380, idealHeight: 460, maxHeight: 620)
        #endif
    }

    /// Generate/regenerate button with an inline spinner while the build runs.
    private var generateRow: some View {
        Group {
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating profile…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(builtAt == nil ? "Generate Profile" : "Regenerate Profile") {
                    generate()
                }
                .disabled(!openRouterConfig.hasAPIKey)
            }
        }
    }

    /// Builds a profile from the album's member prompts and the description as
    /// currently typed (even unsaved). The result lands in the editor for
    /// review; nothing persists until Save.
    private func generate() {
        isGenerating = true
        generationError = nil
        Task {
            defer { isGenerating = false }
            guard let dir = try? await LibraryContainer.shared.itemsDirectory() else {
                generationError = "The library isn't available right now."
                return
            }
            let classifier = OpenRouterClassifier(
                apiKey: openRouterConfig.apiKey ?? "",
                model: openRouterConfig.model)
            let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let builder = AlbumProfileBuilder(itemsDirectory: dir, classifier: classifier)
            if let result = await builder.buildProfile(
                albumID: request.albumID,
                albumName: request.albumName,
                userDescription: description.isEmpty ? nil : description) {
                profileText = result.text
                builtAt = Date()
                memberCount = result.memberCount
            } else {
                generationError = "Couldn't build a profile. The album needs items with generation prompts, and the OpenRouter key and model must be valid."
            }
        }
    }

    /// Writes only what actually changed — each setter rewrites the album file,
    /// which fires the iCloud metadata query and a reconcile, so no-op saves
    /// shouldn't cause churn.
    private func save() {
        isSaving = true
        Task {
            let newDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDescription: String? = newDescription.isEmpty ? nil : newDescription
            if normalizedDescription != request.userDescription {
                await store.albumService.setUserDescription(request.albumID, normalizedDescription)
            }

            // Hand-edits keep the request's original baseline (a correction,
            // not a rebuild — staleness tracking stands); in-sheet generation
            // stamped a fresh builtAt/memberCount above.
            let newProfile = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let builtAt, !newProfile.isEmpty,
               newProfile != request.profileText || builtAt != request.profileBuiltAt {
                await store.albumService.setAIProfile(request.albumID, AlbumAIProfile(
                    text: newProfile,
                    builtAt: builtAt,
                    memberCount: memberCount))
            }

            store.notifyAlbumsChanged()
            dismiss()
        }
    }
}
