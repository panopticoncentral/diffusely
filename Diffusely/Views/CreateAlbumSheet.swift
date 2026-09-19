import SwiftUI

struct CreateAlbumSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var saving = false
    @FocusState private var nameFocused: Bool
    var onCreated: (UUID, String) -> Void = { _, _ in }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Album name", text: $name).focused($nameFocused)
                }
                Section {
                    TextField("Optional description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                } header: { Text("Description") } footer: {
                    Text("Describe what belongs here to help the Sort Assistant suggest items.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(saving || !name.isEmpty || !description.isEmpty)
        .onAppear { nameFocused = true }
        #if os(macOS)
        .frame(width: 460, height: 340)
        #endif
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        Task {
            let id = await store.albumService.createAlbum(name: trimmed)
            let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { await store.albumService.setUserDescription(id, detail) }
            store.notifyAlbumsChanged()
            onCreated(id, trimmed)
            dismiss()
        }
    }
}
