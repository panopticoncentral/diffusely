import SwiftUI

struct ImageFeedItemView: View {
    let image: CivitaiImage
    var isGridMode: Bool = false
    var preserveAspectRatio: Bool = false
    /// Hidden by `UserContentView`, where every thumbnail is by the profile's
    /// own user — the overlay would be redundant and tapping it would push a
    /// duplicate of the profile.
    var showsUsername: Bool = true
    /// When true, the item gains a right-click / long-press context menu
    /// that mirrors the ellipsis overlay. Set only by collection-grid callers;
    /// false elsewhere keeps the main feed and author profile context-menu-free.
    var showsContextMenu: Bool = false
    /// Draws the keyboard-focus ring (macOS grid arrow-key navigation). Set by
    /// the feed grid only; defaults off everywhere else.
    var keyboardFocused: Bool = false

    @State private var isLoadingPost = false
    @State private var postLoadError = false
    @State private var showingCollectionPicker = false
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var librarySaveService = LibrarySaveService.shared

    // All taps push Routes onto the enclosing stack's router, so chains like
    // collection → image → user → post deepen the stack and back walks them
    // one at a time — on both platforms.
    @EnvironmentObject private var router: NavigationRouter
    @Environment(\.zoomTransitionNamespace) private var zoomNamespace
    @Environment(\.openURL) private var openURL

    /// The width/height ratio fed into `.aspectRatio(_:contentMode:)` and frame
    /// math for a cell. Civitai returns 0 for some media dimensions; a raw
    /// `width / height` then yields 0, ∞, or NaN, and handing a non-finite value
    /// to SwiftUI's layout engine trips an assertion inside `LayoutSubview.place`
    /// during lazy scroll prefetch (a hard crash on macOS 26). Always finite and
    /// positive, falling back to square (1) when a dimension is missing.
    static func displayAspectRatio(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    private func openImageDetail() {
        router.push(.image(image))
    }

    private func openUserContent() {
        guard let user = image.user else { return }
        router.push(.user(user))
    }

    // Opt-in context menu — only the collection grid sets
    // `showsContextMenu`, which keeps the main feed and author profile
    // context-menu-free.
    @ViewBuilder
    var body: some View {
        if showsContextMenu {
            bodyCore.contextMenu { menuContent }
        } else {
            bodyCore
        }
    }

    @ViewBuilder
    private var bodyCore: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isGridMode {
                gridContent
            } else {
                listContent
            }
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .image(image)) {
                showingCollectionPicker = false
            }
        }
        .alert("Couldn't Open Post", isPresented: $postLoadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The post couldn't be loaded. Please check your connection and try again.")
        }
    }

    private func loadPost() async {
        guard let postId = image.postId, !isLoadingPost else { return }

        isLoadingPost = true
        do {
            let post = try await civitaiService.getPost(postId: postId)
            router.push(.post(post))
        } catch {
            postLoadError = true
        }
        isLoadingPost = false
    }

    private var hasMenuItems: Bool {
        // "Save to Library" is always available, so the menu always renders.
        true
    }

    /// Shared by the ellipsis overlay and the opt-in context menu so the two
    /// stay in lockstep.
    @ViewBuilder
    private var menuContent: some View {
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
                Label("Manage Collections", systemImage: "folder")
            }
        }

        #if os(macOS)
        // macOS power-user verbs. Right-click on a feed cell is a native
        // expectation there (see the macOS-only `showsContextMenu` on the feed
        // grid); on iOS the feed stays context-menu-free by design.
        Divider()
        if !image.isVideo {
            Button(action: { ImageCopy.copyRemoteImage(urlString: image.detailURL) }) {
                Label("Copy Image", systemImage: "doc.on.doc")
            }
        }
        Button(action: {
            if let url = URL(string: "https://civitai.com/images/\(image.id)") {
                openURL(url)
            }
        }) {
            Label("Open in Browser", systemImage: "safari")
        }
        #endif
    }

    @ViewBuilder
    private var ellipsisMenu: some View {
        if hasMenuItems {
            Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .accessibilityLabel("More actions")
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        let aspectRatio = Self.displayAspectRatio(width: image.width, height: image.height)
        let displayRatio: CGFloat = preserveAspectRatio ? aspectRatio : 1
        GeometryReader { geometry in
            let displayHeight = preserveAspectRatio
                ? geometry.size.width / aspectRatio
                : geometry.size.width
            ZStack {
                FeedGridMedia(
                    image: image,
                    width: geometry.size.width,
                    height: displayHeight,
                    onTap: { openImageDetail() }
                )

                // Legibility scrim behind the bottom username overlay — the plain
                // text shadow washes out over light/busy images. Non-interactive
                // so taps still reach the media beneath.
                if showsUsername, image.user?.username != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.5)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }

                // Overlays
                VStack {
                    HStack {
                        Spacer()
                        if image.isVideo {
                            Image(systemName: "video.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        ellipsisMenu
                            .padding(.leading, 4)
                    }
                    .padding(8)
                    Spacer()
                    if showsUsername, let user = image.user, let username = user.username {
                        HStack {
                            Button(action: { openUserContent() }) {
                                Text(username)
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .shadow(color: .black, radius: 2)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .aspectRatio(displayRatio, contentMode: .fit)
        .clipShape(preserveAspectRatio ? AnyShape(RoundedRectangle(cornerRadius: 8)) : AnyShape(Rectangle()))
        .overlay {
            if keyboardFocused {
                RoundedRectangle(cornerRadius: preserveAspectRatio ? 8 : 0)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // Origin of the iOS zoom push into the image detail view.
        .zoomTransitionSource(id: "image-\(image.id)", in: zoomNamespace)
    }

    @ViewBuilder
    private var listContent: some View {
        if showsUsername, let user = image.user, let username = user.username {
            Button(action: { openUserContent() }) {
                HStack(spacing: 4) {
                    Text(username)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }

        ZStack(alignment: .topTrailing) {
            if image.isVideo {
                let aspectRatio = Self.displayAspectRatio(width: image.width, height: image.height)
                GeometryReader { geometry in
                    ZStack {
                        CachedVideoPlayer(
                            url: image.detailURL,
                            autoPlay: true,
                            isMuted: true
                        )
                        .frame(width: geometry.size.width, height: geometry.size.width / aspectRatio)
                        .allowsHitTesting(false)

                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openImageDetail()
                            }
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                CachedAsyncImage(url: image.detailURL)
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture {
                        openImageDetail()
                    }
            }

            // Ellipsis menu overlay
            ellipsisMenu
                .padding(8)
        }
        // Origin of the iOS zoom push into the image detail view (list mode).
        .zoomTransitionSource(id: "image-\(image.id)", in: zoomNamespace)

        FeedItemStats(
            likeCount: image.stats?.likeCountAllTime ?? 0,
            heartCount: image.stats?.heartCountAllTime ?? 0,
            laughCount: image.stats?.laughCountAllTime ?? 0,
            cryCount: image.stats?.cryCountAllTime ?? 0,
            commentCount: image.stats?.commentCountAllTime ?? 0,
            dislikeCount: image.stats?.dislikeCountAllTime ?? 0
        )
    }
}
