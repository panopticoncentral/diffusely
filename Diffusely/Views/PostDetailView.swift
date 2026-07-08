import SwiftUI

struct PostDetailView: View {
    let post: CivitaiPost

    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()
    @State private var currentImageIndex = 0
    @State private var generationData: GenerationData?
    @State private var isLoadingGenData = false
    @State private var showingCollectionPicker = false
    @ObservedObject private var librarySaveService = LibrarySaveService.shared
    @State private var tags: [CivitaiVotableTag] = []
    @State private var showAllTags = false
    // This view is always pushed by the enclosing stack's router (on both
    // platforms); user and tag drill-ins push further Routes so back walks
    // the chain one level at a time.
    @EnvironmentObject private var router: NavigationRouter

    /// The image currently visible in the carousel, or nil if the post is empty
    /// or the index is somehow out of range (currentImageIndex is unconstrained
    /// @State and can outlive bounds during async post updates).
    private var currentImage: CivitaiImage? {
        post.safeImages.indices.contains(currentImageIndex)
            ? post.safeImages[currentImageIndex]
            : nil
    }

    private func openUserContent() {
        router.push(.user(post.user))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Carousel + stats - scrollable; media fits the window on macOS
                GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !post.safeImages.isEmpty {
                            MediaCarousel(
                                images: post.safeImages,
                                currentIndex: $currentImageIndex,
                                maxHeight: proxy.size.height
                            ) {
                                postMenuContent
                            }
                        }

                        // Stats and generation data
                        VStack(alignment: .leading, spacing: 12) {
                            FeedItemStats(
                                likeCount: post.safeStats.likeCount,
                                heartCount: post.safeStats.heartCount,
                                laughCount: post.safeStats.laughCount,
                                cryCount: post.safeStats.cryCount,
                                commentCount: post.safeStats.commentCount,
                                dislikeCount: post.safeStats.dislikeCount
                            )

                            Divider()

                            // Generation data section
                            if isLoadingGenData {
                                ProgressView()
                                    .padding()
                            } else if let genData = generationData {
                                GenerationDataView(data: genData)
                            }

                            // Tags section for the current carousel image
                            // (hidden entirely when there are no tags).
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
        // Esc pops the pushed post view, matching the toolbar back button.
        .onExitCommand { dismiss() }
        #endif
        .onChange(of: currentImageIndex) {
            showAllTags = false
        }
        // Load per-image metadata with `.task(id:)` so swiping/arrow-keying
        // quickly through pages cancels the in-flight request for the previous
        // index. Two uncancelled Tasks per page-change used to race: whichever
        // response landed last won, so the prompt/params/tags under image N
        // could actually describe image N-1.
        .task(id: currentImageIndex) {
            await loadGenerationData(for: currentImageIndex)
        }
        .task(id: currentImageIndex) {
            await loadTags(for: currentImageIndex)
        }
        .task {
            MediaCacheService.shared.preloadImages(post.safeImages)
        }
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .post(post)) {
                showingCollectionPicker = false
            }
        }
    }

    /// Buttons for the toolbar's ellipsis menu and the media context menu.
    @ViewBuilder
    private var postMenuContent: some View {
        if let currentImage = currentImage {
            let isSavingCurrent = librarySaveService.isSaving(itemID: currentImage.id)
            Button(action: {
                librarySaveService.save(currentImage, knownPostTitle: post.title, knownPublishedAt: post.publishedAtDate)
            }) {
                Label(
                    isSavingCurrent ? "Saving Image…" : "Save Image to Library",
                    systemImage: "square.and.arrow.down"
                )
            }
            .disabled(isSavingCurrent)
        }

        Button(action: {
            librarySaveService.savePost(post)
        }) {
            Label(
                librarySaveService.isSavingPost(post) ? "Saving Post…" : "Save Post to Library",
                systemImage: "square.and.arrow.down.on.square"
            )
        }
        .disabled(librarySaveService.isSavingPost(post))

        if APIKeyManager.shared.hasAPIKey {
            Button(action: {
                showingCollectionPicker = true
            }) {
                Label("Manage Collections", systemImage: "folder")
            }
        }

        if let shareURL = URL(string: "https://civitai.com/posts/\(post.id)") {
            ShareLink(item: shareURL) {
                Label("Share Post", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Toolbar shared by both platforms (this view is pushed on both now).
    /// Extracted to a @ToolbarContentBuilder so the SwiftUI type-checker
    /// doesn't time out on the already-long body modifier chain.
    ///
    /// The username sits in `.principal` as a Menu so it's both visible and
    /// obviously clickable. When the post has a title, it appears as a quiet
    /// secondary line below. We deliberately do NOT set `.navigationTitle` —
    /// when both are set on macOS, both render and the username appears twice.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                if let username = post.user.username {
                    Menu {
                        Button(action: { openUserContent() }) {
                            Label("View \(username)'s content", systemImage: "person.crop.circle")
                        }
                    } label: {
                        Text(username)
                            .font(.headline)
                    }
                    .fixedSize()
                    .help("\(username) — click for actions")
                }
                if let title = post.title {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                postMenuContent
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More actions")
        }
    }

    private func loadGenerationData(for index: Int) async {
        guard index < post.safeImages.count else { return }
        let imageId = post.safeImages[index].id

        // Clear stale data so a failed/empty fetch for the new image doesn't
        // leave the previous image's params on screen.
        generationData = nil
        isLoadingGenData = true
        do {
            let data = try await civitaiService.fetchGenerationData(imageId: imageId)
            guard !Task.isCancelled else { return }
            generationData = data
        } catch {
            // Silently fail - generation data may not be available for all images
        }
        guard !Task.isCancelled else { return }
        isLoadingGenData = false
    }

    private func loadTags(for index: Int) async {
        guard post.safeImages.indices.contains(index) else {
            tags = []
            return
        }
        let fetched = await civitaiService.fetchVotableTags(imageId: post.safeImages[index].id)
        guard !Task.isCancelled else { return }
        tags = fetched
    }
}
