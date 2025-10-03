import SwiftUI

struct ImageFeedItemView: View {
    let image: CivitaiImage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedItemHeader(
                username: image.user?.username, 
                title: nil)

            // Main image/video content
            if image.isVideo {
                CachedVideoPlayer(
                    url: image.detailURL,
                    autoPlay: true,
                    isMuted: true
                )
                .aspectRatio(contentMode: .fit)
            } else {
                CachedAsyncImage(url: image.detailURL)
                    .aspectRatio(contentMode: .fit)
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
        .background(Color(.systemBackground))
    }
}
