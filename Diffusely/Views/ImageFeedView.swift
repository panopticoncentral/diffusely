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
                            if videos {
                                VideoCacheService.shared.preloadAhead(
                                    currentIndex: index,
                                    images: civitaiService.images,
                                    lookahead: 3
                                )
                            } else {
                                ImageCacheService.shared.preloadAhead(
                                    currentIndex: index,
                                    images: civitaiService.images,
                                    lookahead: 5
                                )
                            }

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
                await refreshImages()
            }
            .task {
                if civitaiService.images.isEmpty {
                    await loadImages()
                }
            }
            .onChange(of: selectedRating) { _, _ in Task { await refreshImages() } }
            .onChange(of: selectedPeriod) { _, _ in Task { await refreshImages() } }
            .onChange(of: selectedSort) { _, _ in Task { await refreshImages() } }
        }
    }

    private func loadImages() async {
        await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
    }

    private func refreshImages() async {
        civitaiService.clear()
        await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
    }
}
