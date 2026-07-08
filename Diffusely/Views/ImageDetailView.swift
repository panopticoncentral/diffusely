import SwiftUI

struct ImageDetailView: View {
    /// The feed slice being browsed. A bare `.image` route wraps a single
    /// image; feed grids pass their whole loaded slice so next/previous
    /// paging works from any image (swipe/arrows, like PostDetailView).
    let images: [CivitaiImage]

    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()
    @State private var generationData: GenerationData?
    @State private var isLoadingGenData = false
    @State private var isLoadingPost = false
    @State private var postLoadFailed = false
    @State private var showingCollectionPicker = false
    @ObservedObject private var librarySaveService = LibrarySaveService.shared
    @State private var tags: [CivitaiVotableTag] = []
    @State private var showAllTags = false
    // This view is always pushed by the enclosing stack's router (on both
    // platforms), and every drill-in — post, user, tag — pushes another Route,
    // so back walks the chain one level at a time.
    @EnvironmentObject private var router: NavigationRouter

    init(image: CivitaiImage) {
        self.init(images: [image], initialIndex: 0)
    }

    init(images: [CivitaiImage], initialIndex: Int) {
        self.images = images
        _currentIndex = State(initialValue: min(max(0, initialIndex), max(0, images.count - 1)))
    }

    /// The image currently visible in the carousel. `currentIndex` is clamped
    /// at init and by the carousel, but guard anyway since it's unconstrained
    /// @State.
    private var currentImage: CivitaiImage? {
        images.indices.contains(currentIndex) ? images[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Main content - scrollable
                GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !images.isEmpty {
                            MediaCarousel(
                                images: images,
                                currentIndex: $currentIndex,
                                maxHeight: proxy.size.height
                            ) {
                                detailMenuContent
                            }
                        }

                        // Stats section
                        VStack(alignment: .leading, spacing: 12) {
                            FeedItemStats(
                                likeCount: currentImage?.stats?.likeCountAllTime ?? 0,
                                heartCount: currentImage?.stats?.heartCountAllTime ?? 0,
                                laughCount: currentImage?.stats?.laughCountAllTime ?? 0,
                                cryCount: currentImage?.stats?.cryCountAllTime ?? 0,
                                commentCount: currentImage?.stats?.commentCountAllTime ?? 0,
                                dislikeCount: currentImage?.stats?.dislikeCountAllTime ?? 0
                            )

                            Divider()

                            // Generation data section
                            if isLoadingGenData {
                                ProgressView()
                                    .padding()
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }

                            // Tags section (hidden entirely when there are no
                            // tags or the fetch failed).
                            if !tags.isEmpty {
                                Divider()
                                TagsSectionView(tags: tags, showAll: $showAllTags) { tag in
                                    router.push(.tag(
                                        id: tag.id,
                                        name: tag.name,
                                        videos: currentImage?.isVideo ?? false
                                    ))
                                }
                            }
                        }
                        .padding()
                    }
                }
                .background(Color(.systemBackground))
                }
                }
            }
            .toolbar { detailToolbar }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            // Esc pops the pushed detail view, matching the toolbar back button.
            .onExitCommand { dismiss() }
            // ⌘C copies the current carousel image. Responder-chain based so it
            // doesn't steal Copy from selected generation-metadata text.
            .onCopyCommand {
                guard let image = currentImage, !image.isVideo else { return [] }
                return ImageCopy.remoteImageProviders(urlString: image.detailURL)
            }
            #endif
            .onChange(of: currentIndex) {
                showAllTags = false
            }
            // Load per-image metadata with `.task(id:)` so paging quickly
            // cancels the in-flight request for the previous index (same
            // stale-response guard as PostDetailView).
            .task(id: currentIndex) {
                await loadGenerationData()
            }
            .task(id: currentIndex) {
                await loadTags()
            }
            .sheet(isPresented: $showingCollectionPicker) {
                if let currentImage {
                    ManageCollectionsSheet(target: .image(currentImage)) {
                        showingCollectionPicker = false
                    }
                }
            }
            .alert("Couldn't Load Post", isPresented: $postLoadFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The post couldn't be loaded. Check your connection and try again.")
            }
    }

    /// Buttons for the toolbar's ellipsis menu and the media context menu.
    /// All actions target the image currently visible in the carousel.
    @ViewBuilder
    private var detailMenuContent: some View {
        if let image = currentImage {
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
                    Label(
                        isLoadingPost ? "Loading Post…" : "View Post",
                        systemImage: "photo.stack"
                    )
                }
                .disabled(isLoadingPost)
            }

            if APIKeyManager.shared.hasAPIKey {
                Button(action: {
                    showingCollectionPicker = true
                }) {
                    Label("Manage Collections", systemImage: "folder")
                }
            }

            #if os(macOS)
            if !image.isVideo {
                Button(action: {
                    ImageCopy.copyRemoteImage(urlString: image.detailURL)
                }) {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
            }
            #endif

            if let shareURL = URL(string: "https://civitai.com/images/\(image.id)") {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// Toolbar shared by both platforms (this view is pushed on both now).
    /// Extracted to a @ToolbarContentBuilder so the SwiftUI type-checker
    /// doesn't time out on the already-long body modifier chain.
    ///
    /// The username sits in `.principal` as a Menu so it's both visible and
    /// obviously clickable. We deliberately do NOT set `.navigationTitle` —
    /// when both are set on macOS, both render and the username appears twice.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if let user = currentImage?.user, let username = user.username {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button(action: { router.push(.user(user)) }) {
                        Label("View \(username)'s content", systemImage: "person.crop.circle")
                    }
                } label: {
                    Text(username)
                        .font(.headline)
                }
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

    private func loadGenerationData() async {
        guard let image = currentImage else { return }

        // Clear stale data so a failed/empty fetch for the new image doesn't
        // leave the previous image's params on screen.
        generationData = nil
        isLoadingGenData = true
        do {
            let data = try await civitaiService.fetchGenerationData(imageId: image.id)
            guard !Task.isCancelled else { return }
            generationData = data
        } catch {
            // Silently fail - generation data may not be available for all images
        }
        guard !Task.isCancelled else { return }
        isLoadingGenData = false
    }

    private func loadTags() async {
        guard let image = currentImage else {
            tags = []
            return
        }
        let fetched = await civitaiService.fetchVotableTags(imageId: image.id)
        guard !Task.isCancelled else { return }
        tags = fetched
    }

    private func loadPost() async {
        guard let postId = currentImage?.postId, !isLoadingPost else { return }

        isLoadingPost = true
        do {
            let post = try await civitaiService.getPost(postId: postId)
            router.push(.post(post))
        } catch {
            postLoadFailed = true
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
                    CopyablePromptView(label: "Prompt", text: prompt)
                }

                if let negativePrompt = meta.negativePrompt, !negativePrompt.isEmpty {
                    CopyablePromptView(label: "Negative Prompt", text: negativePrompt)
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

/// Displays a labeled prompt value with a button to copy it to the clipboard.
struct CopyablePromptView: View {
    let label: String
    let text: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Clipboard.copy(text)
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(copied)
            }
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}
