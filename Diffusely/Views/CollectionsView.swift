import SwiftUI

struct CollectionsView: View {
    @StateObject private var apiKeyManager = APIKeyManager.shared
    @StateObject private var civitaiService = CivitaiService()
    @State private var showingSettings = false
    @State private var collections: [CivitaiCollection] = []
    @State private var previewImages: [Int: CivitaiImage] = [:]  // collectionId -> preview image
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Filter to only show Image and Post collections
    var filteredCollections: [CivitaiCollection] {
        collections.filter { collection in
            if let type = collection.type {
                return type == "Image" || type == "Post"
            }
            return false
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !apiKeyManager.hasAPIKey {
                    // Show prompt to add API key
                    VStack(spacing: 20) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("API Key Required")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Enter your Civitai API key in Settings to access your collections")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button(action: {
                            showingSettings = true
                        }) {
                            Label("Open Settings", systemImage: "gear")
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                } else if isLoading {
                    ProgressView("Loading collections...")
                } else if let errorMessage = errorMessage {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("Error Loading Collections")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Retry") {
                            Task {
                                await loadCollections()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if filteredCollections.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("No Collections")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("You don't have any image or post collections yet")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filteredCollections) { collection in
                                NavigationLink(destination: CollectionDetailView(collection: collection)) {
                                    CollectionCard(
                                        collection: collection,
                                        previewImage: previewImages[collection.id]
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                if apiKeyManager.hasAPIKey && collections.isEmpty {
                    await loadCollections()
                }
            }
        }
    }

    private func loadCollections() async {
        isLoading = true
        errorMessage = nil

        do {
            collections = try await civitaiService.getAllUserCollections()

            // Load preview images for collections that need them
            await loadPreviewImages()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadPreviewImages() async {
        await withTaskGroup(of: (Int, CivitaiImage?).self) { group in
            for collection in filteredCollections {
                // Skip if collection already has a cover image
                if collection.image?.fullImageURL != nil {
                    continue
                }

                group.addTask {
                    guard let type = collection.type else { return (collection.id, nil) }
                    let image = try? await self.civitaiService.fetchCollectionPreviewImage(
                        collectionId: collection.id,
                        collectionType: type
                    )
                    return (collection.id, image)
                }
            }

            for await (collectionId, image) in group {
                if let image = image {
                    previewImages[collectionId] = image
                }
            }
        }
    }
}

struct CollectionCard: View {
    let collection: CivitaiCollection
    var previewImage: CivitaiImage?

    private var typeIcon: String {
        switch collection.type {
        case "Image":
            return "photo.stack"
        case "Post":
            return "square.stack.3d.up"
        default:
            return "folder"
        }
    }

    private var typeColor: Color {
        switch collection.type {
        case "Image":
            return .blue
        case "Post":
            return .purple
        default:
            return .gray
        }
    }

    /// Returns the URL to display: collection cover, preview image, or nil
    private var displayImageURL: String? {
        // First try the collection's explicit cover image
        if let coverURL = collection.image?.fullImageURL {
            return coverURL
        }
        // Fall back to fetched preview image
        if let preview = previewImage {
            return preview.detailURL
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background image or placeholder
            GeometryReader { geometry in
                if let imageURL = displayImageURL {
                    CachedAsyncImage(url: imageURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // Gradient placeholder when no cover image
                    LinearGradient(
                        colors: [typeColor.opacity(0.3), typeColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Image(systemName: typeIcon)
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.5))
                    )
                }
            }

            // Bottom gradient overlay for text readability
            LinearGradient(
                colors: [.clear, .black.opacity(0.7), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)

            // Content overlay
            VStack(alignment: .leading, spacing: 4) {
                Spacer()

                Text(collection.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    // Type badge
                    HStack(spacing: 3) {
                        Image(systemName: typeIcon)
                            .font(.system(size: 9))
                        Text(collection.type ?? "")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(typeColor.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(4)

                    // Image count
                    if let imageCount = collection.imageCount, imageCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                            Text("\(imageCount)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.8))
                    }

                    Spacer()
                }
            }
            .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
    }
}
