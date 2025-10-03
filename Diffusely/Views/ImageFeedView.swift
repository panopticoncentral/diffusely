import SwiftUI

struct ImageFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
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
                        ImageFeedItemView(
                            image: image
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
            .onChange(of: selectedRating) { _, _ in refreshImages() }
            .onChange(of: selectedPeriod) { _, _ in refreshImages() }
            .onChange(of: selectedSort) { _, _ in refreshImages() }
        }
    }

    private func refreshImages() {
        civitaiService.clear()
        Task {
            await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
        }
    }
}
