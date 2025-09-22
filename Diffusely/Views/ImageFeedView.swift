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

                        Menu {
                            // Content Menu
                            Menu("Content") {
                                ForEach(ContentRating.allCases) { rating in
                                    Button {
                                        selectedRating = rating
                                    } label: {
                                        HStack {
                                            Text(rating.displayName)
                                            if rating == selectedRating {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }

                            // Time Menu
                            Menu("Time") {
                                ForEach(Timeframe.allCases) { period in
                                    Button {
                                        selectedPeriod = period
                                    } label: {
                                        HStack {
                                            Text(period.displayName)
                                            if period == selectedPeriod {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }

                            // Sort Menu
                            Menu("Sort") {
                                ForEach(FeedSort.allCases) { sort in
                                    Button {
                                        selectedSort = sort
                                    } label: {
                                        HStack {
                                            Image(systemName: sort.icon)
                                            Text(sort.displayName)
                                            if sort == selectedSort {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .frame(width: 44, height: 44)
                        .padding(.trailing, 16)
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
                        Text(image.user.username ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.semibold)
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
                    if image.stats.likeCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsup.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(image.stats.likeCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if image.stats.heartCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("\(formatCount(image.stats.heartCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if image.stats.laughCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.smiling")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(image.stats.laughCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if image.stats.cryCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.dashed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(image.stats.cryCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if image.stats.commentCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "message")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(image.stats.commentCountAllTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if image.stats.dislikeCountAllTime > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsdown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(image.stats.dislikeCountAllTime))")
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
                        Text(image.user.username ?? "")
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

struct DetailItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
        }
    }
}

struct SharedVideoPlayerView: View {
    let image: CivitaiImage
    let index: Int
    let isCurrentIndex: Bool
    
    @State private var individualPlayer = AVPlayer()
    @State private var isLoading = false
    @State private var hasError = false
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        ZStack {
            VideoPlayerView(player: individualPlayer)
                .onAppear {
                    setupPlayer()
                }
                .onChange(of: isCurrentIndex) { oldValue, newValue in
                    if newValue {
                        playVideo()
                    } else {
                        pauseVideo()
                    }
                }
            
            if isLoading && !hasError {
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        VStack(spacing: 16) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                            Text("Loading video...")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                    )
            }
            
            if hasError {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "play.slash")
                                .font(.system(size: 50))
                            Text("Failed to load video")
                                .font(.caption)
                        }
                        .foregroundColor(.gray)
                    )
            }
        }
        .onDisappear {
            individualPlayer.pause()
            individualPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    private func setupPlayer() {
        guard let videoURL = URL(string: image.detailURL) else {
            hasError = true
            return
        }
        
        isLoading = true
        hasError = false
        
        let item = AVPlayerItem(url: videoURL)
        individualPlayer.replaceCurrentItem(with: item)
        
        // Setup audio
        individualPlayer.isMuted = false
        individualPlayer.volume = 1.0
        
        // Monitor status
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                switch status {
                case .readyToPlay:
                    isLoading = false
                    hasError = false
                    if isCurrentIndex {
                        individualPlayer.play()
                    }
                case .failed:
                    isLoading = false
                    hasError = true
                case .unknown:
                    break
                @unknown default:
                    isLoading = false
                    hasError = true
                }
            }
            .store(in: &cancellables)
        
        // Setup looping
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            individualPlayer.seek(to: .zero)
            if isCurrentIndex {
                individualPlayer.play()
            }
        }
        
        if isCurrentIndex {
            playVideo()
        }
    }
    
    private func playVideo() {
        if individualPlayer.currentItem?.status == .readyToPlay {
            individualPlayer.play()
        }
    }
    
    private func pauseVideo() {
        individualPlayer.pause()
    }
}

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    
    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
        view.playerLayer = playerLayer
        return view
    }
    
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer?.player = player
    }
}

class PlayerUIView: UIView {
    var playerLayer: AVPlayerLayer?
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}
