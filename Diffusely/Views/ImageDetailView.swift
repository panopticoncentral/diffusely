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
    #if os(iOS)
    @State private var showingUserContent = false
    #else
    // Push the author's content above THIS view's stack slot rather than at the
    // NavigationStack root, so back returns to the image — not to the collection
    // list it was opened from.
    @State private var pushedUser: CivitaiUser?
    #endif
    @ObservedObject private var librarySaveService = LibrarySaveService.shared

    var body: some View {
        // iOS presents this via fullScreenCover and needs its own NavigationStack
        // to host inner pushes (e.g. View Post). On Mac the view is pushed onto
        // the parent's NavigationStack, so an inner NavigationStack here would
        // be nested — and a nested NavigationStack on macOS clobbers the outer
        // path when an inner-stack push is popped, so back blows past every
        // intermediate view all the way to root. Render bare on Mac so
        // $navigateToPost / $pushedUser attach to the outer stack and back
        // walks the path one level at a time, like the other detail views.
        #if os(iOS)
        NavigationStack {
            coreBody
        }
        #else
        coreBody
        #endif
    }

    @ViewBuilder
    private var coreBody: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                #if os(iOS)
                // iOS-only header. On Mac the equivalent affordances (back via
                // NavigationStack chrome, username, menu) live in `.toolbar`
                // attached at the end of `coreBody` — having a second in-content
                // header on top of the navigation title bar reads as a stray
                // second toolbar.
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.primary)
                            .padding()
                    }

                    if let user = image.user, let username = user.username {
                        Button(action: {
                            showingUserContent = true
                        }) {
                            HStack(spacing: 4) {
                                Text(username)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Menu {
                        detailMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .foregroundColor(.primary)
                            .padding()
                    }
                }
                .background(Color(.systemBackground))
                #endif

                // Main content - scrollable
                GeometryReader { proxy in
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
                            .detailMediaFrame(maxHeight: proxy.size.height)
                        } else {
                            CachedAsyncImage(url: image.detailURL)
                                .aspectRatio(contentMode: .fit)
                                .detailMediaFrame(maxHeight: proxy.size.height)
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

                            // Generation data section
                            if isLoadingGenData {
                                ProgressView()
                                    .padding()
                                    .padding()
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }
                        }
                        .padding()
                    }
                }
                .background(Color(.systemBackground))
                }
                }
            }
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            #if os(macOS)
            .toolbar { macToolbar }
            #endif
            .task {
                await loadGenerationData()
            }
            .navigationDestination(item: $navigateToPost) { post in
                PostDetailView(post: post)
            }
            #if os(macOS)
            .navigationDestination(item: $pushedUser) { user in
                UserContentView(user: user)
            }
            #endif
            .sheet(isPresented: $showingCollectionPicker) {
                ManageCollectionsSheet(target: .image(image)) {
                    showingCollectionPicker = false
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingUserContent) {
                if let user = image.user {
                    UserContentView(user: user)
                }
            }
            #endif
    }

    /// Buttons shared between the iOS in-content menu and the macOS toolbar
    /// menu. Same actions, different chrome wrapping them. The "View User"
    /// entry is Mac-only — on iOS the username is already a button in the
    /// in-content header, so the menu would be redundant.
    @ViewBuilder
    private var detailMenuContent: some View {
        Button(action: {
            librarySaveService.save(image)
        }) {
            Label(
                librarySaveService.isSaving(itemID: image.id) ? "Saving to Library…" : "Save to Library",
                systemImage: "square.and.arrow.down"
            )
        }
        .disabled(librarySaveService.isSaving(itemID: image.id))

        if image.postId != nil {
            Button(action: {
                Task { await loadPost() }
            }) {
                Label("View Post", systemImage: "photo.stack")
            }
        }

        if APIKeyManager.shared.hasAPIKey {
            Button(action: {
                showingCollectionPicker = true
            }) {
                Label("Manage Collections", systemImage: "folder")
            }
        }
    }

    #if os(macOS)
    /// macOS toolbar — replaces the in-content header used on iOS. Extracted
    /// to a @ToolbarContentBuilder so the SwiftUI type-checker doesn't time
    /// out on the already-long `coreBody` modifier chain.
    ///
    /// The username sits in `.principal` as a Menu so it's both visible and
    /// obviously clickable (Menu renders a small disclosure chevron natively
    /// on Mac). We deliberately do NOT set `.navigationTitle` here — when
    /// both are set on macOS, both render and the username appears twice.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        if let user = image.user, let username = user.username {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button(action: { pushedUser = user }) {
                        Label("View \(username)'s content", systemImage: "person.crop.circle")
                    }
                } label: {
                    Text(username)
                        .font(.headline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("\(username) — click for actions")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                detailMenuContent
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More actions")
        }
    }
    #endif

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
                .foregroundColor(.primary)

            if let meta = data.meta {
                if let prompt = meta.prompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(prompt)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }

                if let negativePrompt = meta.negativePrompt, !negativePrompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Negative Prompt")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(negativePrompt)
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }

                HStack(spacing: 16) {
                    if let steps = meta.steps {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steps")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(steps)")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }

                    if let cfgScale = meta.cfgScale {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CFG Scale")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f", cfgScale))
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }

                    if let sampler = meta.sampler {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sampler")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(sampler)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }

                    if let seed = meta.seed {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Seed")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(seed)")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                }
            }

            if let resources = data.resources, !resources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Models")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    ForEach(Array(resources.enumerated()), id: \.offset) { _, resource in
                        HStack(spacing: 8) {
                            if let modelName = resource.modelName {
                                Text(modelName)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            if let modelType = resource.modelType {
                                Text("(\(modelType))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let strength = resource.strength {
                                Text(String(format: "%.2f", strength))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
