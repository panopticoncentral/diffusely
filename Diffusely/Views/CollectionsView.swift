import SwiftUI

struct CollectionsView: View {
    @StateObject private var apiKeyManager = APIKeyManager.shared
    @StateObject private var civitaiService = CivitaiService()
    @State private var showingSettings = false
    @State private var collections: [CivitaiCollection] = []
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
                        LazyVStack(spacing: 16) {
                            ForEach(filteredCollections) { collection in
                                NavigationLink(destination: CollectionDetailView(collection: collection)) {
                                    CollectionCard(collection: collection)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding()
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
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct CollectionCard: View {
    let collection: CivitaiCollection

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

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 60, height: 60)

                Image(systemName: typeIcon)
                    .font(.system(size: 26))
                    .foregroundColor(typeColor)
            }

            // Content
            VStack(alignment: .leading, spacing: 6) {
                Text(collection.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)

                if let description = collection.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    if let type = collection.type {
                        HStack(spacing: 4) {
                            Image(systemName: typeIcon)
                                .font(.system(size: 11))
                            Text(type)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(typeColor)
                    }

                    if let imageCount = collection.imageCount, imageCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11))
                            Text("\(imageCount)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
    }
}
