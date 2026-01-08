import SwiftUI

struct ImageFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let videos: Bool

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

                    if isGridLayout {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                                ImageFeedItemView(image: image, isGridMode: true)
                                    .onAppear {
                                        if image.id == civitaiService.images.last?.id {
                                            Task {
                                                await loadMoreImages()
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 2)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                                ImageFeedItemView(image: image, isGridMode: false)
                                    .onAppear {
                                        if image.id == civitaiService.images.last?.id {
                                            Task {
                                                await loadMoreImages()
                                            }
                                        }
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

    private func loadMoreImages() async {
        await civitaiService.loadMoreImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
    }

    private func refreshImages() async {
        civitaiService.clear()
        await loadImages()
    }
}
