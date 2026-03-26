import SwiftUI

struct ImageFeedItemView: View {
    let image: CivitaiImage
    var isGridMode: Bool = false

    @State private var showingDetail = false
    @State private var navigateToPost: CivitaiPost?
    @State private var isLoadingPost = false
    @State private var showingCollectionPicker = false
    @State private var showingUserContent = false
    @StateObject private var civitaiService = CivitaiService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isGridMode {
                gridContent
            } else {
                listContent
            }
        }
        .background(Color(.systemBackground))
        .fullScreenCover(isPresented: $showingDetail) {
            ImageDetailView(image: image)
        }
        .fullScreenCover(item: $navigateToPost) { post in
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

    private func loadPost() async {
        guard let postId = image.postId, !isLoadingPost else { return }

        isLoadingPost = true
        do {
            let post = try await civitaiService.getPost(postId: postId)
            navigateToPost = post
        } catch {
            // Silently fail
        }
        isLoadingPost = false
    }

    private var hasMenuItems: Bool {
        image.postId != nil || APIKeyManager.shared.hasAPIKey
    }

    @ViewBuilder
    private var ellipsisMenu: some View {
        if hasMenuItems {
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
        GeometryReader { geometry in
            ZStack {
                if image.isVideo {
                    CachedVideoPlayer(
                        url: image.detailURL,
                        autoPlay: true,
                        isMuted: true
                    )
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .clipped()
                    .allowsHitTesting(false)
                } else {
                    CachedAsyncImage(url: image.detailURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .clipped()
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingDetail = true
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
                            Button(action: { showingUserContent = true }) {
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
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var listContent: some View {
        if let user = image.user, let username = user.username {
            Button(action: { showingUserContent = true }) {
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
                                showingDetail = true
                            }
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                CachedAsyncImage(url: image.detailURL)
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture {
                        showingDetail = true
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
