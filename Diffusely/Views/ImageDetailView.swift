import SwiftUI

struct ImageDetailView: View {
    let image: CivitaiImage

    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()
    @State private var generationData: GenerationData?
    @State private var isLoadingGenData = false
    @State private var navigateToPost: CivitaiPost?
    @State private var isLoadingPost = false
    @State private var showingCollectionPicker = false
    @State private var showingUserContent = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding()
                    }

                    if let user = image.user, let username = user.username {
                        Button(action: { showingUserContent = true }) {
                            HStack(spacing: 4) {
                                Text(username)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Menu {
                        if image.postId != nil {
                            Button(action: {
                                Task {
                                    await loadPost()
                                }
                            }) {
                                Label("View Post", systemImage: "photo.stack")
                            }
                        }

                        if APIKeyManager.shared.hasAPIKey {
                            Button(action: {
                                showingCollectionPicker = true
                            }) {
                                Label("Add to Collection", systemImage: "folder.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                .background(Color.black.opacity(0.3))

                // Main content - scrollable
                ScrollView {
                    VStack(spacing: 0) {
                        // Image/Video
                        if image.isVideo {
                            let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
                            CachedVideoPlayer(
                                url: image.detailURL,
                                autoPlay: true,
                                isMuted: false
                            )
                            .aspectRatio(aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        } else {
                            CachedAsyncImage(url: image.detailURL)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }

                        // Stats section
                        VStack(alignment: .leading, spacing: 12) {
                            FeedItemStats(
                                likeCount: image.stats?.likeCountAllTime ?? 0,
                                heartCount: image.stats?.heartCountAllTime ?? 0,
                                laughCount: image.stats?.laughCountAllTime ?? 0,
                                cryCount: image.stats?.cryCountAllTime ?? 0,
                                commentCount: image.stats?.commentCountAllTime ?? 0,
                                dislikeCount: image.stats?.dislikeCountAllTime ?? 0
                            )

                            Divider()
                                .background(Color.white.opacity(0.2))

                            // Generation data section
                            if isLoadingGenData {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding()
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }
                        }
                        .padding()
                    }
                }
                .background(Color.black)
                }
            }
            .navigationBarHidden(true)
            .task {
                await loadGenerationData()
            }
            .navigationDestination(item: $navigateToPost) { post in
                PostDetailView(post: post)
            }
            .sheet(isPresented: $showingCollectionPicker) {
                CollectionPickerView(itemType: .image(id: image.id)) {
                    showingCollectionPicker = false
                }
            }
            .fullScreenCover(isPresented: $showingUserContent) {
                if let user = image.user {
                    UserContentView(user: user)
                }
            }
        }
    }

    private func loadGenerationData() async {
        isLoadingGenData = true
        do {
            generationData = try await civitaiService.fetchGenerationData(imageId: image.id)
        } catch {
            // Silently fail - generation data may not be available for all images
        }
        isLoadingGenData = false
    }

    private func loadPost() async {
        guard let postId = image.postId, !isLoadingPost else { return }

        isLoadingPost = true
        do {
            let post = try await civitaiService.getPost(postId: postId)
            navigateToPost = post
        } catch {
            // Silently fail - could show an error message here if needed
        }
        isLoadingPost = false
    }
}

struct GenerationDataView: View {
    let data: GenerationData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generation Info")
                .font(.headline)
                .foregroundColor(.white)

            if let meta = data.meta {
                if let prompt = meta.prompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                        Text(prompt)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }

                if let negativePrompt = meta.negativePrompt, !negativePrompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Negative Prompt")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                        Text(negativePrompt)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }

                HStack(spacing: 16) {
                    if let steps = meta.steps {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steps")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Text("\(steps)")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }

                    if let cfgScale = meta.cfgScale {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CFG Scale")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.1f", cfgScale))
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }

                    if let sampler = meta.sampler {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sampler")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Text(sampler)
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }

                    if let seed = meta.seed {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Seed")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Text("\(seed)")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                }
            }

            if let resources = data.resources, !resources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Models")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))

                    ForEach(Array(resources.enumerated()), id: \.offset) { _, resource in
                        HStack(spacing: 8) {
                            if let modelName = resource.modelName {
                                Text(modelName)
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            if let modelType = resource.modelType {
                                Text("(\(modelType))")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            if let strength = resource.strength {
                                Text(String(format: "%.2f", strength))
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                }
            }
        }
    }
}
