import SwiftUI
import AVKit
import Combine

struct ImageFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @State private var selectedImage: CivitaiImage?
    @State private var showingFilters = false
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: ImageSort

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

                        Button {
                            showingFilters = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.title2)
                                .foregroundColor(.primary)
                        }
                        .padding(.trailing, 20)
                        .padding(.top, 8)
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
            .onChange(of: selectedRating) { _, newRating in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: newRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedPeriod) { _, newPeriod in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: newPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedSort) { _, newSort in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: newSort)
                }
            }


        }
        .fullScreenCover(item: $selectedImage) { image in
            ImageDetailView(
                image: image,
                isPresented: Binding(
                    get: { selectedImage != nil },
                    set: { if !$0 { selectedImage = nil } }
                )
            )
        }
        .sheet(isPresented: $showingFilters) {
            FiltersSheet(
                selectedRating: $selectedRating,
                selectedPeriod: $selectedPeriod,
                selectedSort: $selectedSort,
                isPresented: $showingFilters
            )
        }
    }
}

struct FeedItemView: View {
    let image: CivitaiImage
    let onTap: () -> Void

    @State private var showingDetails = false

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
                        Text(image.username ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(formatDate(image.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: {
                    showingDetails.toggle()
                }) {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundColor(.primary)
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
                    if let likes = image.stats.likeCount, likes > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(likes))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let comments = image.stats.commentCount, comments > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "message")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(comments))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if image.stats.collectedCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bookmark")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(image.stats.collectedCountAllTime))")
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
                        Text(image.username ?? "")
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
        .onAppear {
            print("📱 FeedItem appeared for image: \(image.id)")
        }
        .onDisappear {
            print("📱 FeedItem disappeared for image: \(image.id)")
        }
        .sheet(isPresented: $showingDetails) {
            ImageDetailSheet(image: image)
        }
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let now = Date()
            let timeInterval = now.timeIntervalSince(date)

            if timeInterval < 60 {
                return "now"
            } else if timeInterval < 3600 {
                let minutes = Int(timeInterval / 60)
                return "\(minutes)m"
            } else if timeInterval < 86400 {
                let hours = Int(timeInterval / 3600)
                return "\(hours)h"
            } else if timeInterval < 604800 {
                let days = Int(timeInterval / 86400)
                return "\(days)d"
            } else {
                let weeks = Int(timeInterval / 604800)
                return "\(weeks)w"
            }
        }
        return ""
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1000000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        } else {
            return "\(count)"
        }
    }
}


struct ImageDetailView: View {
    let image: CivitaiImage
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if image.isVideo {
                SharedVideoPlayerView(
                    image: image,
                    index: 0,
                    isCurrentIndex: true
                )
            } else {
                AsyncImage(url: URL(string: image.detailURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure(_):
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                VStack {
                                    Image(systemName: "photo")
                                        .font(.system(size: 50))
                                    Text("Failed to load")
                                }
                                .foregroundColor(.gray)
                            )
                    case .empty:
                        Rectangle()
                            .fill(Color.clear)
                            .overlay(
                                ProgressView()
                                    .tint(.white)
                            )
                    @unknown default:
                        EmptyView()
                    }
                }
            }

            VStack {
                HStack {
                    Button(action: {
                        isPresented = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 100)
                    .offset(y: -20)
                )
                Spacer()
            }
        }
        .statusBarHidden()
    }
}

struct ImageDetailSheet: View {
    let image: CivitaiImage

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let meta = image.meta {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Generation Details")
                                .font(.headline)

                            if let prompt = meta.prompt {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Prompt")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(prompt)
                                        .font(.caption)
                                }
                            }

                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                if let model = meta.model {
                                    DetailItem(title: "Model", value: model)
                                }
                                if let steps = meta.steps {
                                    DetailItem(title: "Steps", value: "\(steps)")
                                }
                                if let sampler = meta.sampler {
                                    DetailItem(title: "Sampler", value: sampler)
                                }
                                if let cfgScale = meta.cfgScale {
                                    DetailItem(title: "CFG Scale", value: String(format: "%.1f", cfgScale))
                                }
                                if let seed = meta.seed {
                                    DetailItem(title: "Seed", value: "\(seed)")
                                }
                                if let size = meta.size {
                                    DetailItem(title: "Size", value: size)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
