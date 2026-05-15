import SwiftUI

#if os(macOS)
struct RefreshFeedAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

struct RefreshFeedActionKey: FocusedValueKey {
    typealias Value = RefreshFeedAction
}

extension FocusedValues {
    var refreshFeed: RefreshFeedAction? {
        get { self[RefreshFeedActionKey.self] }
        set { self[RefreshFeedActionKey.self] = newValue }
    }
}
#endif

struct ImageFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var domainManager = DomainManager.shared
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
        #if os(macOS)
        feedScroll
            .navigationTitle(videos ? "Videos" : "Images")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    FeedFilterMenu(
                        selectedPeriod: $selectedPeriod,
                        selectedSort: $selectedSort
                    )
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshImages() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .focusedSceneValue(\.refreshFeed, RefreshFeedAction {
                Task { await refreshImages() }
            })
        #else
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
                    selectedPeriod: $selectedPeriod,
                    selectedSort: $selectedSort
                )
            }
            .background(Color(.systemBackground))

            feedScroll
        }
        #endif
    }

    private var feedScroll: some View {
        ScrollView {
            feedContent

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
        .refreshable {
            await refreshImages()
        }
        .task {
            if civitaiService.images.isEmpty {
                await loadImages()
            }
        }
        .onChange(of: selectedPeriod) { _, _ in Task { await refreshImages() } }
        .onChange(of: selectedSort) { _, _ in Task { await refreshImages() } }
        .onChange(of: domainManager.domain) { _, _ in Task { await refreshImages() } }
    }

    @ViewBuilder
    private var feedContent: some View {
        #if os(macOS)
        WaterfallGrid(images: civitaiService.images) {
            Task { await loadMoreImages() }
        }
        #else
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
        #endif
    }

    private func loadImages() async {
        await civitaiService.fetchImages(videos: videos, period: selectedPeriod, sort: selectedSort)
    }

    private func loadMoreImages() async {
        await civitaiService.loadMoreImages(videos: videos, period: selectedPeriod, sort: selectedSort)
    }

    private func refreshImages() async {
        civitaiService.clear()
        await loadImages()
    }
}
