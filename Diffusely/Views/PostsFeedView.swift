import SwiftUI

struct PostsFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @State private var selectedPost: CivitaiPost?
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Sticky header that scrolls with content
                    HStack {
                        Text("Posts")
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

                    ForEach(Array(civitaiService.posts.enumerated()), id: \.element.id) { index, post in
                        PostItemView(
                            post: post,
                            onTap: { selectedPost = post }
                        )
                        .onAppear {
                            // Load more content when reaching the end
                            if post.id == civitaiService.posts.last?.id {
                                Task {
                                    await civitaiService.loadMorePosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
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
                await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
            }
            .task {
                if civitaiService.posts.isEmpty {
                    await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedRating) { _, newRating in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchPosts(browsingLevel: newRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedPeriod) { _, newPeriod in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: newPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedSort) { _, newSort in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: newSort)
                }
            }
        }
        .fullScreenCover(item: $selectedPost) { post in
            PostDetailView(
                post: post,
                isPresented: Binding(
                    get: { selectedPost != nil },
                    set: { if !$0 { selectedPost = nil } }
                )
            )
        }
    }
}

struct PostItemView: View {
    let post: CivitaiPost
    let onTap: () -> Void

    @State private var showingDetails = false
    @State private var currentImageIndex = 0

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
                        Text(post.user.username ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        if let title = post.title, !title.isEmpty {
                            Text(title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
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
                            Text("\(formatCount(post.stats.likeCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.heartCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("\(formatCount(post.stats.heartCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.laughCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.smiling")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(post.stats.laughCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.cryCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "face.dashed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(post.stats.cryCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.commentCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "message")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(post.stats.commentCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if post.stats.dislikeCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsdown")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(formatCount(post.stats.dislikeCount))")
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
        .sheet(isPresented: $showingDetails) {
            PostDetailSheet(post: post)
        }
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

struct PostDetailView: View {
    let post: CivitaiPost
    @Binding var isPresented: Bool
    @State private var currentImageIndex = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !post.images.isEmpty {
                TabView(selection: $currentImageIndex) {
                    ForEach(Array(post.images.enumerated()), id: \.element.id) { index, image in
                        if image.isVideo {
                            SharedVideoPlayerView(
                                image: image,
                                index: index,
                                isCurrentIndex: currentImageIndex == index
                            )
                            .tag(index)
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
                            .tag(index)
                        }
                    }
                }
                .tabViewStyle(.page)
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

                    if post.images.count > 1 {
                        Text("\(currentImageIndex + 1) / \(post.images.count)")
                            .foregroundColor(.white)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(8)
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
        }
        .statusBarHidden()
    }
}

struct PostDetailSheet: View {
    let post: CivitaiPost

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let title = post.title, !title.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Title")
                                .font(.headline)
                            Text(title)
                                .font(.body)
                        }
                    }

                    Text("Post Statistics")
                        .font(.headline)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        DetailItem(title: "Images", value: "\(post.imageCount)")
                        DetailItem(title: "Likes", value: "\(post.stats.likeCount)")
                        DetailItem(title: "Hearts", value: "\(post.stats.heartCount)")
                        DetailItem(title: "Comments", value: "\(post.stats.commentCount)")
                    }

                    if !post.images.isEmpty,
                       let firstImage = post.images.first,
                       let meta = firstImage.meta {
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
            .navigationTitle("Post Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

