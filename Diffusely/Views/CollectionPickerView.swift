import SwiftUI

enum CollectionItemType {
    case image(id: Int)
    case post(id: Int)

    var displayName: String {
        switch self {
        case .image: return "image"
        case .post: return "post"
        }
    }
}

struct CollectionPickerView: View {
    let itemType: CollectionItemType
    let onDismiss: () -> Void

    @StateObject private var civitaiService = CivitaiService()
    @State private var collections: [CivitaiCollection] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var addingToCollectionId: Int?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading collections...")
                } else if let error = error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if collections.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "folder")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No \(itemType.displayName) collections found")
                            .foregroundColor(.secondary)
                        Text("Create a \(itemType.displayName) collection on Civitai to add \(itemType.displayName)s to it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(collections) { collection in
                        Button(action: {
                            Task {
                                await addToCollection(collection)
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(collection.name)
                                        .foregroundColor(.primary)
                                    if let description = collection.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if addingToCollectionId == collection.id {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .disabled(addingToCollectionId != nil)
                    }
                }
            }
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
            .overlay {
                if let successMessage = successMessage {
                    VStack {
                        Spacer()
                        Text(successMessage)
                            .padding()
                            .background(Color.green.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding()
                    }
                }
            }
        }
        .task {
            await loadCollections()
        }
    }

    private func loadCollections() async {
        isLoading = true
        error = nil

        do {
            switch itemType {
            case .image:
                collections = try await civitaiService.getUserImageCollections()
            case .post:
                collections = try await civitaiService.getUserPostCollections()
            }
        } catch {
            self.error = "Failed to load collections"
        }

        isLoading = false
    }

    private func addToCollection(_ collection: CivitaiCollection) async {
        addingToCollectionId = collection.id

        do {
            switch itemType {
            case .image(let imageId):
                try await civitaiService.addImageToCollection(imageId: imageId, collectionId: collection.id)
            case .post(let postId):
                try await civitaiService.addPostToCollection(postId: postId, collectionId: collection.id)
            }
            successMessage = "Added to \(collection.name)"

            // Dismiss after a short delay
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            onDismiss()
        } catch {
            print("Failed to add to collection: \(error)")
            print("Error details: \(error.localizedDescription)")
            self.error = "Failed to add to collection: \(error.localizedDescription)"
        }

        addingToCollectionId = nil
    }
}
