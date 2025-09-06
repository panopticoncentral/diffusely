import SwiftUI
import AVKit
import Combine

struct ImageCarouselView: View {
    let images: [CivitaiImage]
    @Binding var selectedIndex: Int
    @Binding var isPresented: Bool
    
    @State private var showingDetails = false
    @State private var detailOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @StateObject private var videoPlayerManager = VideoPlayerManager()
    
    private let detailThreshold: CGFloat = 150
    
    var currentImage: CivitaiImage? {
        guard selectedIndex < images.count else { return nil }
        return images[selectedIndex]
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Full-screen image carousel
                TabView(selection: $selectedIndex) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        ZStack {
                            if image.isVideo {
                                SharedVideoPlayerView(
                                    image: image,
                                    videoPlayerManager: videoPlayerManager,
                                    index: index,
                                    isCurrentIndex: selectedIndex == index
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
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle())
                .ignoresSafeArea()
                
                // Top toolbar overlay
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
                        
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                showingDetails = true
                            }
                        }) {
                            Image(systemName: "info.circle")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
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
                .opacity(showingDetails ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: showingDetails)
                
                // Stats text bar at bottom
                if let currentImage = currentImage {
                    VStack {
                        Spacer()
                        StatsTextBar(image: currentImage)
                    }
                    .opacity(showingDetails ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: showingDetails)
                }
                
                // Photos app-style slide up detail panel
                if showingDetails {
                    PhotosDetailPanel(
                        image: currentImage,
                        isShowing: $showingDetails,
                        offset: $detailOffset
                    )
                    .transition(.move(edge: .bottom))
                    .offset(y: detailOffset + dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = max(0, value.translation.height)
                            }
                            .onEnded { value in
                                withAnimation(.spring()) {
                                    if value.translation.height > detailThreshold {
                                        showingDetails = false
                                        detailOffset = 0
                                    } else {
                                        detailOffset = 0
                                    }
                                    dragOffset = 0
                                }
                            }
                    )
                }
            }
        }
        .statusBarHidden()
        .onDisappear {
            videoPlayerManager.stop()
        }
    }
    
}

struct PhotosDetailPanel: View {
    let image: CivitaiImage?
    @Binding var isShowing: Bool
    @Binding var offset: CGFloat
    
    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.gray)
                .frame(width: 40, height: 5)
                .padding(.top, 8)
            
            if let image = image {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // User info
                        HStack {
                            if let username = image.username {
                                VStack(alignment: .leading) {
                                    Text(username)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(formatDate(image.createdAt))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            
                            Button(action: {
                                withAnimation(.spring()) {
                                    isShowing = false
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Stats
                        HStack(spacing: 20) {
                            if let likes = image.stats.likeCount {
                                Label("\(likes)", systemImage: "heart")
                            }
                            if let comments = image.stats.commentCount {
                                Label("\(comments)", systemImage: "message")
                            }
                            if let hearts = image.stats.heartCount {
                                Label("\(hearts)", systemImage: "heart.fill")
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        
                        // Generation details
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
                .frame(maxHeight: 500)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
        )
        .padding(.horizontal)
    }
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return dateString
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
    @ObservedObject var videoPlayerManager: VideoPlayerManager
    let index: Int
    let isCurrentIndex: Bool
    
    var body: some View {
        ZStack {
            VideoPlayer(player: videoPlayerManager.player)
                .onAppear {
                    if isCurrentIndex {
                        videoPlayerManager.playVideo(url: image.detailURL, at: index)
                    }
                }
                .onChange(of: isCurrentIndex) { oldValue, newValue in
                    if newValue {
                        videoPlayerManager.playVideo(url: image.detailURL, at: index)
                    } else if videoPlayerManager.currentVideoIndex == index {
                        videoPlayerManager.pause()
                    }
                }
                .opacity(videoPlayerManager.isLoading ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: videoPlayerManager.isLoading)
            
            if videoPlayerManager.isLoading && !videoPlayerManager.hasError {
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
            
            if videoPlayerManager.hasError {
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
    }
}


struct StatsTextBar: View {
    let image: CivitaiImage
    
    var body: some View {
        HStack(spacing: 16) {
            formatStatsWithIcons()
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
        )
    }
    
    private func formatStatsWithIcons() -> some View {
        HStack(spacing: 16) {
            if let likes = image.stats.likeCount, likes > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "heart")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text(formatCount(likes))
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
            if let comments = image.stats.commentCount, comments > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "message")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text(formatCount(comments))
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
            if let hearts = image.stats.heartCount, hearts > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text(formatCount(hearts))
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
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
