import SwiftUI

struct PostsFeedItemView: View {
    let post: CivitaiPost

    @State private var currentImageIndex = 0
    @State private var currentHeight: CGFloat = UIScreen.main.bounds.width
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedItemHeader(
                username: post.user.username,
                title: post.title
            )

            if !post.images.isEmpty {
                GeometryReader { geometry in
                    TabView(selection: $currentImageIndex) {
                        ForEach(Array(post.images.enumerated()), id: \.element.id) { index, image in
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
                                CachedAsyncImage(url: image.detailURL)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geometry.size.width)
                                    .tag(index)
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: currentImageIndex) { oldValue, newIndex in
                        if newIndex < post.images.count {
                            let image = post.images[newIndex]
                            let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
                            withAnimation(.easeInOut(duration: 0.3)) {
                                currentHeight = geometry.size.width / aspectRatio
                            }
                        }
                    }
                }
                .frame(height: currentHeight)
                .onAppear {
                    if !post.images.isEmpty {
                        let image = post.images[0]
                        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
                        currentHeight = UIScreen.main.bounds.width / aspectRatio
                    }
                }
                .onTapGesture {
                    showingDetail = true
                }

                // Custom page indicator and image counter
                if post.images.count > 1 {
                    HStack {
                        Spacer()

                        // Image counter
                        Text("\(currentImageIndex + 1)/\(post.images.count)")
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
                likeCount: post.stats.likeCount,
                heartCount: post.stats.heartCount,
                laughCount: post.stats.laughCount,
                cryCount: post.stats.cryCount,
                commentCount: post.stats.commentCount,
                dislikeCount: post.stats.dislikeCount
            )
        }
        .background(Color(.systemBackground))
        .fullScreenCover(isPresented: $showingDetail) {
            PostDetailView(post: post)
        }
    }
}
