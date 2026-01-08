import SwiftUI

struct CollectionDetailView: View {
    let collection: CivitaiCollection
    @StateObject private var civitaiService = CivitaiService()
    @State private var selectedRating: ContentRating = .xxx
    @State private var selectedPeriod: Timeframe = .allTime
    @State private var selectedSort: FeedSort = .newest
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isGridLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ]
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text(collection.name)
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

                    if collection.type == "Image" {
                        if isGridLayout {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                                    ImageFeedItemView(image: image, isGridMode: true)
                                        .onAppear {
                                            handleImageAppear(index: index, image: image)
                                        }
                                }
                            }
                            .padding(.horizontal, 2)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                                    ImageFeedItemView(image: image, isGridMode: false)
                                        .onAppear {
                                            handleImageAppear(index: index, image: image)
                                        }
                                }
                            }
                        }
                    } else if collection.type == "Post" {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(civitaiService.posts.enumerated()), id: \.element.id) { index, post in
                                PostsFeedItemView(post: post)
                                    .onAppear {
                                        let startIndex = max(0, index - 1)
                                        let endIndex = min(civitaiService.posts.count - 1, index + 3)
                                        let imagesToPreload = Array(civitaiService.posts[startIndex...endIndex]).flatMap { $0.safeImages }

                                        MediaCacheService.shared.preloadImages(imagesToPreload)

                                        if post.id == civitaiService.posts.last?.id {
                                            Task {
                                                await civitaiService.loadMorePosts(
                                                    browsingLevel: selectedRating.browsingLevelValue,
                                                    period: selectedPeriod,
                                                    sort: selectedSort,
                                                    collectionId: collection.id
                                                )
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.top, 100)
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
                await refreshContent()
            }
            .task {
                await loadContent()
            }
            .onChange(of: selectedRating) { _, _ in Task { await refreshContent() } }
            .onChange(of: selectedPeriod) { _, _ in Task { await refreshContent() } }
            .onChange(of: selectedSort) { _, _ in Task { await refreshContent() } }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadContent() async {
        if collection.type == "Image" {
            await civitaiService.fetchImages(
                videos: false,
                browsingLevel: selectedRating.browsingLevelValue,
                period: selectedPeriod,
                sort: selectedSort,
                collectionId: collection.id
            )
        } else if collection.type == "Post" {
            await civitaiService.fetchPosts(
                browsingLevel: selectedRating.browsingLevelValue,
                period: selectedPeriod,
                sort: selectedSort,
                collectionId: collection.id
            )
        }
    }

    private func refreshContent() async {
        civitaiService.clear()
        await loadContent()
    }

    private func handleImageAppear(index: Int, image: CivitaiImage) {
        let lookahead = 5
        let startIndex = max(0, index - 2)
        let endIndex = min(civitaiService.images.count - 1, index + lookahead)
        let imagesToPreload = Array(civitaiService.images[startIndex...endIndex])

        MediaCacheService.shared.preloadImages(imagesToPreload)

        if image.id == civitaiService.images.last?.id {
            Task {
                await civitaiService.loadMoreImages(
                    videos: false,
                    browsingLevel: selectedRating.browsingLevelValue,
                    period: selectedPeriod,
                    sort: selectedSort,
                    collectionId: collection.id
                )
            }
        }
    }
}
