import SwiftUI

struct PostDetailView: View {
    let post: CivitaiPost

    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()
    @State private var currentImageIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var generationData: GenerationData?
    @State private var isLoadingGenData = false
    @State private var showingCollectionPicker = false
    #if os(iOS)
    @State private var showingUserContent = false
    #endif
    #if os(macOS)
    // Tracks the paged ScrollView's snapped position so it stays in sync with
    // currentImageIndex when arrow keys drive the change.
    @State private var scrollPositionID: Int? = 0
    #endif
    @FocusState private var carouselFocused: Bool
    @ObservedObject private var librarySaveService = LibrarySaveService.shared

    #if os(macOS)
    // Push the author's content above THIS view's stack slot (not at the
    // NavigationStack root via feedNavigator) so back returns to the post
    // rather than collapsing past it to the collection list.
    @State private var pushedUser: CivitaiUser?
    #endif

    /// The image currently visible in the carousel, or nil if the post is empty
    /// or the index is somehow out of range (currentImageIndex is unconstrained
    /// @State and can outlive bounds during async post updates).
    private var currentImage: CivitaiImage? {
        post.safeImages.indices.contains(currentImageIndex)
            ? post.safeImages[currentImageIndex]
            : nil
    }

    private func openUserContent() {
        #if os(macOS)
        pushedUser = post.user
        #else
        showingUserContent = true
        #endif
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                #if os(iOS)
                // iOS-only header. On Mac the equivalent affordances (back via
                // NavigationStack chrome, username, post title, menu) move into
                // `.toolbar` at the end of the body — having a second in-content
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

                    VStack(alignment: .leading, spacing: 2) {
                        if let username = post.user.username {
                            Button(action: { openUserContent() }) {
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

                        if let title = post.title {
                            Text(title)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Menu {
                        postMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .foregroundColor(.primary)
                            .padding()
                    }
                }
                .background(Color(.systemBackground))
                #endif

                // Carousel + stats - scrollable; media fits the window on macOS
                GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !post.safeImages.isEmpty {
                            GeometryReader { geometry in
                                #if os(macOS)
                                // macOS gets a paged horizontal ScrollView. The default
                                // TabView style on macOS renders one tab button per image
                                // at the top, which clashes with the custom dot indicator
                                // we render below; ScrollView paging gives a clean
                                // trackpad/keyboard-driven carousel instead.
                                ScrollView(.horizontal) {
                                    LazyHStack(spacing: 0) {
                                        ForEach(Array(post.safeImages.enumerated()), id: \.element.id) { index, image in
                                            mediaCell(for: image, maxHeight: geometry.size.height)
                                                .frame(width: geometry.size.width, height: geometry.size.height)
                                                .id(index)
                                        }
                                    }
                                    .scrollTargetLayout()
                                }
                                .scrollTargetBehavior(.paging)
                                .scrollPosition(id: $scrollPositionID)
                                .scrollIndicators(.hidden)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .focusable()
                                .focused($carouselFocused)
                                .onKeyPress(.leftArrow) { advance(by: -1); return .handled }
                                .onKeyPress(.rightArrow) { advance(by: 1); return .handled }
                                .overlay(alignment: .bottom) {
                                    // Float the indicator inside the carousel
                                    // (which fills the window on macOS) so it's
                                    // visible without scrolling. Capsule with a
                                    // material backing keeps the dots legible
                                    // over any image content beneath them.
                                    pageIndicator
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.thinMaterial, in: Capsule())
                                        .padding(.bottom, 12)
                                }
                                #else
                                TabView(selection: $currentImageIndex) {
                                    ForEach(Array(post.safeImages.enumerated()), id: \.element.id) { index, image in
                                        mediaCell(for: image, maxHeight: geometry.size.height)
                                            .tag(index)
                                    }
                                }
                                .tabViewStyle(.page(indexDisplayMode: .never))
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .focusable()
                                .focused($carouselFocused)
                                .onKeyPress(.leftArrow) { advance(by: -1); return .handled }
                                .onKeyPress(.rightArrow) { advance(by: 1); return .handled }
                                #endif
                            }
                            #if os(macOS)
                            .frame(height: proxy.size.height)
                            #else
                            .frame(minHeight: 400, idealHeight: 500)
                            #endif

                            // iOS: dots sit below the carousel (the carousel has
                            // a fixed idealHeight so there's room). On macOS the
                            // carousel claims the full window height, so the
                            // dots are rendered as an overlay inside the
                            // ScrollView above instead — they'd otherwise be
                            // pushed below the visible area.
                            #if os(iOS)
                            pageIndicator
                                .padding(.vertical, 12)
                            #endif
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
        .onChange(of: currentImageIndex) { _, newIndex in
            #if os(macOS)
            // Keep the paged ScrollView in lockstep when arrow keys (or any
            // future programmatic change) drive currentImageIndex.
            if scrollPositionID != newIndex {
                scrollPositionID = newIndex
            }
            #endif
            Task {
                await loadGenerationData(for: newIndex)
            }
        }
        #if os(macOS)
        .onChange(of: scrollPositionID) { _, new in
            // User-driven swipe/scroll: mirror back into currentImageIndex so
            // the dot indicator and generation-data load follow the snap.
            if let new, new != currentImageIndex {
                currentImageIndex = new
            }
        }
        #endif
        .task {
            MediaCacheService.shared.preloadImages(post.safeImages)
            await loadGenerationData(for: currentImageIndex)
            // Seed keyboard focus so arrow keys work without a prior click.
            // The post view fills the screen and has no competing focusables.
            carouselFocused = true
        }
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .post(post)) {
                showingCollectionPicker = false
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingUserContent) {
            UserContentView(user: post.user)
        }
        #else
        .navigationDestination(item: $pushedUser) { user in
            UserContentView(user: user)
        }
        #endif
    }

    /// Row of small dots showing which image in the post is currently visible.
    /// Used inline below the carousel on iOS and floated over the image on
    /// macOS (where the carousel claims the full window height).
    @ViewBuilder
    private var pageIndicator: some View {
        if post.safeImages.count > 1 {
            HStack(spacing: 6) {
                ForEach(0..<post.safeImages.count, id: \.self) { index in
                    Circle()
                        .fill(currentImageIndex == index ? Color.primary : Color.primary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    /// Renders a single carousel cell sized to the available height, picking
    /// video vs image based on the media type. Extracted so the iOS TabView
    /// branch and the macOS ScrollView branch can share identical media body.
    @ViewBuilder
    private func mediaCell(for image: CivitaiImage, maxHeight: CGFloat) -> some View {
        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
        if image.isVideo {
            CachedVideoPlayer(
                url: image.detailURL,
                autoPlay: true,
                isMuted: false
            )
            .aspectRatio(aspectRatio, contentMode: .fit)
            .detailMediaFrame(maxHeight: maxHeight)
        } else {
            CachedAsyncImage(
                url: image.detailURL,
                expectedAspectRatio: aspectRatio
            )
            .aspectRatio(contentMode: .fit)
            .detailMediaFrame(maxHeight: maxHeight)
        }
    }

    /// Clamped step through the post's images. Used by left/right arrow keys on
    /// both platforms; withAnimation ensures the iOS TabView page-curl and the
    /// macOS paged ScrollView both transition smoothly instead of jumping.
    private func advance(by delta: Int) {
        let count = post.safeImages.count
        guard count > 0 else { return }
        let next = max(0, min(currentImageIndex + delta, count - 1))
        guard next != currentImageIndex else { return }
        withAnimation { currentImageIndex = next }
    }

    /// Menu buttons shared between the iOS in-content menu and the macOS
    /// toolbar menu. Same actions, different chrome wrapping them. The
    /// "View User" entry is Mac-only — on iOS the username is already a
    /// button in the in-content header, so the menu would be redundant.
    @ViewBuilder
    private var postMenuContent: some View {
        if let currentImage = currentImage {
            let isSavingCurrent = librarySaveService.isSaving(itemID: currentImage.id)
            Button(action: {
                librarySaveService.save(currentImage, knownPostTitle: post.title)
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
    }

    #if os(macOS)
    /// macOS toolbar — replaces the in-content header used on iOS. Extracted
    /// to a @ToolbarContentBuilder so the SwiftUI type-checker doesn't time
    /// out on the already-long body modifier chain.
    ///
    /// The username sits in `.principal` as a Menu so it's both visible and
    /// obviously clickable (Menu renders a small disclosure chevron natively
    /// on Mac). When the post has a title, it appears as a quiet secondary
    /// line below. We deliberately do NOT set `.navigationTitle` here —
    /// when both are set on macOS, both render and the username appears
    /// twice.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
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
                    .menuStyle(.borderlessButton)
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
    #endif

    private func loadGenerationData(for index: Int) async {
        guard index < post.safeImages.count else { return }
        let imageId = post.safeImages[index].id

        isLoadingGenData = true
        do {
            generationData = try await civitaiService.fetchGenerationData(imageId: imageId)
        } catch {
            // Silently fail - generation data may not be available for all images
        }
        isLoadingGenData = false
    }
}
