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
        MasonryGrid(
            items: civitaiService.images,
            aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
        ) { image in
            ImageFeedItemView(image: image, isGridMode: true, preserveAspectRatio: true)
                .onAppear { maybeLoadMore(for: image) }
        }
        #else
        if isGridLayout {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(civitaiService.images, id: \.id) { image in
                    ImageFeedItemView(image: image, isGridMode: true)
                        .onAppear { maybeLoadMore(for: image) }
                }
            }
            .padding(.horizontal, 2)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(civitaiService.images, id: \.id) { image in
                    ImageFeedItemView(image: image, isGridMode: false)
                        .onAppear { maybeLoadMore(for: image) }
                }
            }
        }
        #endif
    }

    /// Kicks off the next page when `image` is the prefetch trigger (≈5 items
    /// from the end) or the very last item. The 5-from-end trigger gives the
    /// network a head start so the user rarely hits the bottom spinner; the
    /// last-item check is a backstop in case fast scrolling skips the trigger's
    /// onAppear. loadMoreImages' own !isLoading guard dedups the two.
    private func maybeLoadMore(for image: CivitaiImage) {
        let items = civitaiService.images
        let prefetchTriggerID = items.count > 5 ? items[items.count - 5].id : items.first?.id
        if image.id == prefetchTriggerID || image.id == items.last?.id {
            Task { await loadMoreImages() }
        }
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
