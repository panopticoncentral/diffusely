import SwiftUI

/// Detail view for a single feed image. Feeds are terminal: tapping an image
/// opens exactly that image with no left/right paging — browsing happens in
/// the grid, not here. Multi-item paging (`MediaCarousel`) is reserved for
/// genuine containers like a post's images.
struct ImageDetailView: View {
    let image: CivitaiImage

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

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Main content - scrollable
                GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        media(maxHeight: proxy.size.height)

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
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }

                            // Tags section (hidden entirely when there are no
                            // tags or the fetch failed).
                            if !tags.isEmpty {
                                Divider()
                                TagsSectionView(tags: tags, showAll: $showAllTags) { tag in
                                    router.push(.tag(id: tag.id, name: tag.name, videos: image.isVideo))
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
        // ⌘C copies the image. Responder-chain based so it doesn't steal
        // Copy from selected generation-metadata text.
        .onCopyCommand {
            guard !image.isVideo else { return [] }
            return ImageCopy.remoteImageProviders(urlString: image.detailURL)
        }
        #endif
        .task {
            await loadGenerationData()
        }
        .task {
            await loadTags()
        }
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .image(image)) {
                showingCollectionPicker = false
            }
        }
        .alert("Couldn't Load Post", isPresented: $postLoadFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The post couldn't be loaded. Check your connection and try again.")
        }
    }

    /// The single media view. Videos autoplay muted so opening a detail view
    /// doesn't blast audio (the transport exposes an unmute control); stills
    /// get the zoomable wrapper. Right-click / long-press mirrors the toolbar
    /// actions on the media itself.
    @ViewBuilder
    private func media(maxHeight: CGFloat) -> some View {
        let aspectRatio = ImageFeedItemView.displayAspectRatio(width: image.width, height: image.height)
        Group {
            if image.isVideo {
                CachedVideoPlayer(
                    url: image.detailURL,
                    autoPlay: true,
                    isMuted: true
                )
                .aspectRatio(aspectRatio, contentMode: .fit)
                .detailMediaFrame(maxHeight: maxHeight)
            } else {
                ZoomableView {
                    CachedAsyncImage(url: image.detailURL, expectedAspectRatio: aspectRatio)
                        .aspectRatio(contentMode: .fit)
                }
                .detailMediaFrame(maxHeight: maxHeight)
            }
        }
        .contextMenu { detailMenuContent }
    }

    /// Buttons for the toolbar's ellipsis menu and the media context menu.
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

    /// Toolbar shared by both platforms (this view is pushed on both now).
    /// Extracted to a @ToolbarContentBuilder so the SwiftUI type-checker
    /// doesn't time out on the already-long body modifier chain.
    ///
    /// The username sits in `.principal` as a Menu so it's both visible and
    /// obviously clickable. We deliberately do NOT set `.navigationTitle` —
    /// when both are set on macOS, both render and the username appears twice.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if let user = image.user, let username = user.username {
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
        let fetched = await civitaiService.fetchVotableTags(imageId: image.id)
        guard !Task.isCancelled else { return }
        tags = fetched
    }

    private func loadPost() async {
        guard let postId = image.postId, !isLoadingPost else { return }

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

                // Adaptive grid instead of a single HStack: four params (a long
                // sampler name especially) overflowed the row on narrow iPhones.
                // The grid wraps to as many rows as needed.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), alignment: .topLeading)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    if let steps = meta.steps {
                        metaField("Steps", "\(steps)")
                    }
                    if let cfgScale = meta.cfgScale {
                        metaField("CFG Scale", String(format: "%.1f", cfgScale))
                    }
                    if let sampler = meta.sampler {
                        metaField("Sampler", sampler)
                    }
                    if let seed = meta.seed {
                        metaField("Seed", "\(seed)")
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

    /// A labeled generation-parameter value. Values are text-selectable so the
    /// seed (and the rest) can be copied out.
    private func metaField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}

/// Displays a labeled prompt value with a button to copy it to the clipboard.
struct CopyablePromptView: View {
    let label: String
    let text: String

    @State private var copied = false
    @State private var expanded = false

    /// Prompts collapse to this many lines until expanded.
    private let collapsedLineLimit = 6
    /// Only offer "Show more" for prompts long enough to actually clip at the
    /// line limit. Character-count heuristic (prompts are dense comma-separated
    /// tag lists), which avoids a fragile truncation measurement.
    private var isLong: Bool { text.count > 280 }

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
                .lineLimit(expanded ? nil : collapsedLineLimit)
            if isLong {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation { expanded.toggle() }
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
        }
    }
}
