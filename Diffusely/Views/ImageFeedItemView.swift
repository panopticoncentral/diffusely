import SwiftUI

struct ImageFeedItemView: View {
    let image: CivitaiImage
    let onTap: () -> Void

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
                    isMuted: true,
                    onTap: onTap
                )
                .aspectRatio(contentMode: .fit)
            } else {
                CachedAsyncImageSimple(url: image.detailURL)
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture {
                        onTap()
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
        .background(Color(.systemBackground))
    }
}
