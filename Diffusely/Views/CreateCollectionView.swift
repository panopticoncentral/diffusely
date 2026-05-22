import SwiftUI

/// Sheet for creating a new Image ("Photo / Video") or Post collection.
struct CreateCollectionView: View {
    /// Called after a collection is successfully created (passes the new id).
    /// The parent uses this to refresh its list.
    let onCreated: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()

    private enum CollectionTypeChoice: String, CaseIterable, Identifiable {
        case image = "Image"
        case post = "Post"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .image: return "Photo / Video"
            case .post: return "Post"
            }
        }
    }

    private enum Privacy: String, CaseIterable, Identifiable {
        case `private` = "Private"
        case unlisted = "Unlisted"
        case `public` = "Public"
        var id: String { rawValue }
        var label: String { rawValue }
    }

    @State private var type: CollectionTypeChoice = .image
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var privacy: Privacy = .private
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let nameLimit = 30
    private let descriptionLimit = 300

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(CollectionTypeChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Name") {
                    TextField("Collection name", text: $name)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > nameLimit {
                                name = String(newValue.prefix(nameLimit))
                            }
                        }
                }

                Section("Description") {
                    TextField("Optional", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: description) { _, newValue in
                            if newValue.count > descriptionLimit {
                                description = String(newValue.prefix(descriptionLimit))
                            }
                        }
                }

                Section("Privacy") {
                    Picker("Privacy", selection: $privacy) {
                        ForEach(Privacy.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("New Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
            .alert("Couldn't Create Collection",
                   isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 460)
        #endif
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let id = try await civitaiService.createCollection(
                name: trimmedName,
                type: type.rawValue,
                description: description,
                read: privacy.rawValue
            )
            onCreated(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
