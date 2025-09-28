import SwiftUI
import AVKit
import Combine

struct ImageFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @State private var selectedImage: CivitaiImage?
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort

    let videos: Bool

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Sticky header that scrolls with content
                    HStack {
                        Text(videos ? "Videos" : "Images")
                            .font(.system(size: 34, weight: .bold, design: .default))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                        Spacer()

                        FeedFilterMenu(
                            selectedRating: $selectedRating,
                            selectedPeriod: $selectedPeriod,
                            selectedSort: $selectedSort
                        )
                    }
                    .background(Color(.systemBackground))

                    ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                        FeedItemView(
                            image: image,
                            onTap: { selectedImage = image }
                        )
                        .onAppear {
                            // Preload images ahead
                            ImageCacheService.shared.preloadAhead(
                                currentIndex: index,
                                images: civitaiService.images,
                                lookahead: 5
                            )

                            // Preload videos ahead
                            VideoCacheService.shared.preloadAhead(
                                currentIndex: index,
                                images: civitaiService.images,
                                lookahead: 3
                            )

                            // Load more content when reaching the end
                            if image.id == civitaiService.images.last?.id {
                                Task {
                                    await civitaiService.loadMore(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 50)
                .padding(.bottom, 20)

                if civitaiService.isLoading {
                    ProgressView()
                        .padding()
                }

                if let error = civitaiService.error {
                    Text("Error: \(error.localizedDescription)")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .ignoresSafeArea(.all)
            .refreshable {
                civitaiService.clear()
                await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
            }
            .task {
                if civitaiService.images.isEmpty {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: (selectedRating, selectedPeriod, selectedSort)) { _, _ in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
        }
    }
}

struct FeedItemView: View {
    let image: CivitaiImage
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with user info
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundColor(.gray)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.user?.username ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

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
