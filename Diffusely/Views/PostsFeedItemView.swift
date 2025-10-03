import SwiftUI

struct PostsFeedItemView: View {
    let post: CivitaiPost
    let onTap: () -> Void

    @State private var currentImageIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedItemHeader(
                username: post.user.username,
                title: post.title
            )

            // Full-width image carousel for all images
            if !post.images.isEmpty {
                GeometryReader { geometry in
                    TabView(selection: $currentImageIndex) {
                        ForEach(Array(post.images.enumerated()), id: \.element.id) { index, image in
                            if image.isVideo {
                                CachedVideoPlayer(
                                    url: image.detailURL,
                                    autoPlay: false,
                                    isMuted: true,
                                    onTap: onTap
                                )
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .tag(index)
                            } else {
                                CachedAsyncImageSimple(url: image.detailURL)
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .clipped()
                                    .onTapGesture {
                                        onTap()
                                    }
                                    .tag(index)
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
                .frame(height: UIScreen.main.bounds.width) // Square aspect ratio

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

            // Statistics
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    if post.stats.likeCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsup.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(post.stats.likeCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.heartCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("\(FormatUtilities.formatCount(post.stats.heartCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.laughCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.smiling")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(post.stats.laughCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.cryCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.dashed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(post.stats.cryCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.commentCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "message")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(post.stats.commentCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.dislikeCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsdown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(FormatUtilities.formatCount(post.stats.dislikeCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Show first image's prompt if available
                if let firstImage = post.images.first,
                   let prompt = firstImage.meta?.prompt, !prompt.isEmpty {
                    HStack(alignment: .top) {
                        Text(post.user.username ?? "")
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
