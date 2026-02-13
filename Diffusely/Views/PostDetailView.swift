import SwiftUI

struct PostDetailView: View {
    let post: CivitaiPost

    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()
    @State private var currentImageIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var generationData: GenerationData?
    @State private var isLoadingGenData = false
    @State private var showingCollectionPicker = false
    @State private var showingUserContent = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if let username = post.user.username {
                            Button(action: { showingUserContent = true }) {
                                HStack(spacing: 4) {
                                    Text(username)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        if let title = post.title {
                            Text(title)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if APIKeyManager.shared.hasAPIKey {
                        Menu {
                            Button(action: {
                                showingCollectionPicker = true
                            }) {
                                Label("Add to Collection", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                }
                .background(Color.black.opacity(0.3))

                // Image/Video carousel - outside ScrollView to prevent gesture conflicts
                if !post.safeImages.isEmpty {
                    GeometryReader { geometry in
                        TabView(selection: $currentImageIndex) {
                            ForEach(Array(post.safeImages.enumerated()), id: \.element.id) { index, image in
                                if image.isVideo {
                                    let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
                                    CachedVideoPlayer(
                                        url: image.detailURL,
                                        autoPlay: true,
                                        isMuted: false
                                    )
                                    .aspectRatio(aspectRatio, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .tag(index)
                                } else {
                                    CachedAsyncImage(url: image.detailURL)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity)
                                        .tag(index)
                                }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(height: UIScreen.main.bounds.height * 0.6)

                    // Image counter
                    if post.safeImages.count > 1 {
                        HStack {
                            ForEach(0..<post.safeImages.count, id: \.self) { index in
                                Circle()
                                    .fill(currentImageIndex == index ? Color.white : Color.white.opacity(0.4))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }

                // Stats and generation data - scrollable content
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        FeedItemStats(
                            likeCount: post.safeStats.likeCount,
                            heartCount: post.safeStats.heartCount,
                            laughCount: post.safeStats.laughCount,
                            cryCount: post.safeStats.cryCount,
                            commentCount: post.safeStats.commentCount,
                            dislikeCount: post.safeStats.dislikeCount
                        )

                        Divider()
                            .background(Color.white.opacity(0.2))

                        // Generation data section
                        if isLoadingGenData {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .padding()
                        } else if let genData = generationData {
                            GenerationDataView(data: genData)
                        }
                    }
                    .padding()
                }
                .background(Color.black)
            }
        }
        .navigationBarHidden(true)
        .onChange(of: currentImageIndex) { _, newIndex in
            Task {
                await loadGenerationData(for: newIndex)
            }
        }
        .task {
            await loadGenerationData(for: currentImageIndex)
        }
        .sheet(isPresented: $showingCollectionPicker) {
            CollectionPickerView(itemType: .post(id: post.id)) {
                showingCollectionPicker = false
            }
        }
        .fullScreenCover(isPresented: $showingUserContent) {
            UserContentView(user: post.user)
        }
    }

    private func loadGenerationData(for index: Int) async {
        guard index < post.safeImages.count else { return }
        let imageId = post.safeImages[index].id

        isLoadingGenData = true
        do {
            generationData = try await civitaiService.fetchGenerationData(imageId: imageId)
        } catch {
            // Silently fail - generation data may not be available for all images
        }
        isLoadingGenData = false
    }
}
