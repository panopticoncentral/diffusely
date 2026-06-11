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

    let request: Request
    @State private var descriptionText: String
    @State private var profileText: String
    @State private var isSaving = false

    init(request: Request) {
        self.request = request
        _descriptionText = State(initialValue: request.userDescription ?? "")
        _profileText = State(initialValue: request.profileText ?? "")
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

                if request.profileText != nil {
                    Section {
                        TextEditor(text: $profileText)
                            .frame(minHeight: 100)
                    } header: {
                        Text("AI Profile")
                    } footer: {
                        if let builtAt = request.profileBuiltAt {
                            Text("Built from \(request.profileMemberCount) item\(request.profileMemberCount == 1 ? "" : "s") on \(builtAt.formatted(date: .abbreviated, time: .omitted)). The assistant rebuilds it when the album has doubled in size; your edits steer sorting until then.")
                        }
                    }
                } else {
                    Section("AI Profile") {
                        Text("No profile yet — the Sort Assistant builds one on its next run, from this album's items and your description.")
                            .foregroundStyle(.secondary)
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

            let newProfile = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let original = request.profileText, !newProfile.isEmpty, newProfile != original {
                // Keep the original baseline: editing the wording is a
                // correction, not a rebuild, so staleness tracking stands.
                await store.albumService.setAIProfile(request.albumID, AlbumAIProfile(
                    text: newProfile,
                    builtAt: request.profileBuiltAt ?? Date(),
                    memberCount: request.profileMemberCount))
            }

            store.notifyAlbumsChanged()
            dismiss()
        }
    }
}
