import SwiftUI

/// A feed scoped to a single tag, opened by tapping a tag chip on a detail
/// view or a row in the Tags list. Modeled on `UserContentView`'s scoped-feed
/// pattern.
///
/// The media type is seeded by the caller — the type of the media the chip was
/// tapped from, or images when opened from the Tags list, which has no such
/// context — and is then switchable in the toolbar.
struct TagFeedView: View {
    let tagId: Int
    let tagName: String

    @State private var videos: Bool

    init(tagId: Int, tagName: String, videos: Bool) {
        self.tagId = tagId
        self.tagName = tagName
        _videos = State(initialValue: videos)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var domainManager = DomainManager.shared
    @State private var selectedPeriod: Timeframe = .week
    @State private var selectedSort: FeedSort = .mostCollected
    /// Gates the empty state so "No images found" can't flash on the first frame
    /// before the initial `.task` load runs.
    @State private var hasLoadedOnce = false

    private var isGridLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                feedContent

                if civitaiService.isLoading {
                    ProgressView()
                        .padding()
                }

                if civitaiService.images.isEmpty && !civitaiService.isLoading && hasLoadedOnce {
                    emptyStateView
                }
            }
            .refreshable {
                await refreshContent()
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(tagName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Media", selection: $videos) {
                    Label("Images", systemImage: "photo").tag(false)
                    Label("Videos", systemImage: "video").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                FeedFilterMenu(selectedPeriod: $selectedPeriod, selectedSort: $selectedSort)
            }
        }
        .task {
            await loadContent()
            hasLoadedOnce = true
        }
        .onChange(of: videos) { _, _ in
            Task { await refreshContent() }
        }
        .onChange(of: selectedPeriod) { _, _ in
            Task { await refreshContent() }
        }
        .onChange(of: selectedSort) { _, _ in
            Task { await refreshContent() }
        }
        .onChange(of: domainManager.domain) { _, _ in
            Task { await refreshContent() }
        }
    }

    /// Shared by macOS and regular-width iOS (iPad) so both get the same
    /// staggered wall of natural-aspect-ratio cells.
    private var masonryFeed: some View {
        MasonryGrid(
            items: civitaiService.images,
            aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
        ) { image in
            ImageFeedItemView(
                image: image,
                isGridMode: true,
                preserveAspectRatio: true
            )
            .onAppear {
                if image.id == civitaiService.images.last?.id {
                    Task { await loadMore() }
                }
            }
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        #if os(macOS)
        masonryFeed
        #else
        if isGridLayout {
            masonryFeed
        } else {
            LazyVStack(spacing: 0) {
                ForEach(civitaiService.images) { image in
                    ImageFeedItemView(image: image, isGridMode: false)
                        .onAppear {
                            if image.id == civitaiService.images.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: videos ? "video" : "photo")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No \(videos ? "videos" : "images") found")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 60)
    }

    private func loadContent() async {
        await civitaiService.fetchImages(
            videos: videos,
            period: selectedPeriod,
            sort: selectedSort,
            tags: [tagId]
        )
    }

    private func loadMore() async {
        await civitaiService.loadMoreImages(
            videos: videos,
            period: selectedPeriod,
            sort: selectedSort,
            tags: [tagId]
        )
    }

    private func refreshContent() async {
        civitaiService.clear()
        await loadContent()
    }
}
