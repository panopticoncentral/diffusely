import SwiftUI

struct PostsFeedItemView: View {
    let post: CivitaiPost

    @State private var currentImageIndex = 0
    @State private var currentHeight: CGFloat = 400
    @State private var showingDetail = false
    @State private var showingCollectionPicker = false
    @State private var showingUserContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let username = post.user.username {
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

            if !post.safeImages.isEmpty {
                ZStack(alignment: .topTrailing) {
                    GeometryReader { geometry in
                        TabView(selection: $currentImageIndex) {
                            ForEach(Array(post.safeImages.enumerated()), id: \.element.id) { index, image in
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
                                        }
                                    }
                                    .aspectRatio(aspectRatio, contentMode: .fit)
                                    .tag(index)
                                } else {
                                    CachedAsyncImage(
                                        url: image.detailURL,
                                        expectedAspectRatio: CGFloat(image.width) / CGFloat(image.height)
                                    )
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: geometry.size.width)
                                        .tag(index)
                                }
                            }
                        }
                        #if os(iOS)
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        #endif
                        .onChange(of: currentImageIndex) { oldValue, newIndex in
                            if newIndex < post.safeImages.count {
                                let image = post.safeImages[newIndex]
                                let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentHeight = geometry.size.width / aspectRatio
                                }
                            }
                        }
                    }
                    .frame(height: currentHeight)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        if !post.safeImages.isEmpty {
                            let image = post.safeImages[0]
                            let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
                            currentHeight = width / aspectRatio
                        }
                    }
                    .onTapGesture {
                        showingDetail = true
                    }

                    // Ellipsis menu overlay
                    ellipsisMenu
                        .padding(8)
                }

                // Custom page indicator and image counter
                if post.safeImages.count > 1 {
                    HStack {
                        Spacer()

                        // Image counter
                        Text("\(currentImageIndex + 1)/\(post.safeImages.count)")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(12)
                            .padding(.trailing, 12)
                            .padding(.top, -30)
                    }
                }
            }

            FeedItemStats(
                likeCount: post.safeStats.likeCount,
                heartCount: post.safeStats.heartCount,
                laughCount: post.safeStats.laughCount,
                cryCount: post.safeStats.cryCount,
                commentCount: post.safeStats.commentCount,
                dislikeCount: post.safeStats.dislikeCount
            )
        }
        .background(Color(.systemBackground))
        #if os(iOS)
        .fullScreenCover(isPresented: $showingDetail) {
            PostDetailView(post: post)
        }
        #else
        .sheet(isPresented: $showingDetail) {
            PostDetailView(post: post)
        }
        #endif
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .post(id: post.id)) {
                showingCollectionPicker = false
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingUserContent) {
            UserContentView(user: post.user)
        }
        #else
        .sheet(isPresented: $showingUserContent) {
            UserContentView(user: post.user)
        }
        #endif
    }

    @ViewBuilder
    private var ellipsisMenu: some View {
        if APIKeyManager.shared.hasAPIKey {
            Menu {
                Button(action: {
                    showingCollectionPicker = true
                }) {
                    Label("Add to Collection", systemImage: "folder.badge.plus")
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
}
