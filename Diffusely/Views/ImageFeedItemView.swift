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

            // Statistics only
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    if let stats = image.stats, stats.likeCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsup.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(stats.likeCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let stats = image.stats, stats.heartCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("\(FormatUtilities.formatCount(stats.heartCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let stats = image.stats, stats.laughCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.smiling")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(stats.laughCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let stats = image.stats, stats.cryCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.dashed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(stats.cryCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let stats = image.stats, stats.commentCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "message")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(stats.commentCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let stats = image.stats, stats.dislikeCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsdown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(stats.dislikeCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if let prompt = image.meta?.prompt, !prompt.isEmpty {
                    HStack(alignment: .top) {
                        Text(image.user?.username ?? "")
                            .fontWeight(.semibold) +
                        Text(" \(prompt)")
                    }
                    .font(.subheadline)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

}
