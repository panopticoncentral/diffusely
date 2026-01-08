import SwiftUI

struct ImageFeedItemView: View {
    let image: CivitaiImage
    var isGridMode: Bool = false

    @State private var showingDetail = false

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

                // Video indicator overlay
                if image.isVideo {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "video.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var listContent: some View {
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
