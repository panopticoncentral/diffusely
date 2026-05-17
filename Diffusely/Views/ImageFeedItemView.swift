import SwiftUI

struct ImageFeedItemView: View {
    let image: CivitaiImage
    var isGridMode: Bool = false
    var preserveAspectRatio: Bool = false

    #if os(iOS)
    @State private var showingDetail = false
    @State private var navigateToPost: CivitaiPost?
    @State private var showingUserContent = false
    #endif
    @State private var isLoadingPost = false
    @State private var showingCollectionPicker = false
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var librarySaveService = LibrarySaveService.shared

    #if os(macOS)
    @EnvironmentObject private var feedNavigator: FeedNavigator
    #endif

    private func openImageDetail() {
        #if os(macOS)
        feedNavigator.push(image)
        #else
        showingDetail = true
        #endif
    }

    private func openUserContent() {
        guard let user = image.user else { return }
        #if os(macOS)
        feedNavigator.push(user)
        #else
        showingUserContent = true
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isGridMode {
                gridContent
            } else {
                listContent
            }
        }
        .background(Color(.systemBackground))
        #if os(iOS)
        .fullScreenCover(isPresented: $showingDetail) {
            ImageDetailView(image: image)
        }
        .fullScreenCover(item: $navigateToPost) { post in
            PostDetailView(post: post)
        }
        #endif
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .image(id: image.id)) {
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

    private func loadPost() async {
        guard let postId = image.postId, !isLoadingPost else { return }

        isLoadingPost = true
        do {
            let post = try await civitaiService.getPost(postId: postId)
            #if os(macOS)
            feedNavigator.push(post)
            #else
            navigateToPost = post
            #endif
        } catch {
            // Silently fail
        }
        isLoadingPost = false
    }

    private var hasMenuItems: Bool {
        // "Save to Library" is always available, so the menu always renders.
        true
    }

    @ViewBuilder
    private var ellipsisMenu: some View {
        if hasMenuItems {
            Menu {
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
                        Label("Add to Collection", systemImage: "folder.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
        let displayRatio: CGFloat = preserveAspectRatio ? aspectRatio : 1
        GeometryReader { geometry in
            let displayHeight = preserveAspectRatio
                ? geometry.size.width / aspectRatio
                : geometry.size.width
            ZStack {
                if image.isVideo {
                    CachedVideoPlayer(
                        url: image.detailURL,
                        autoPlay: true,
                        isMuted: true
                    )
                    .frame(width: geometry.size.width, height: displayHeight)
                    .clipped()
                    .allowsHitTesting(false)
                } else {
                    CachedAsyncImage(url: image.detailURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: displayHeight)
                        .clipped()
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openImageDetail()
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
                    if let user = image.user, let username = user.username {
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
    }

    @ViewBuilder
    private var listContent: some View {
        if let user = image.user, let username = user.username {
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
                let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
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
