import SwiftUI

/// A feed scoped to a single tag, opened by tapping a tag chip on a detail
/// view. Fixed to one media type (the type of the media the tag was tapped
/// from). Modeled on `UserContentView`'s scoped-feed pattern.
struct TagFeedView: View {
    let tagId: Int
    let tagName: String
    let videos: Bool

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

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ]
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
                filterMenu
            }
        }
        .task {
            await loadContent()
            hasLoadedOnce = true
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

    @ViewBuilder
    private var feedContent: some View {
        #if os(macOS)
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
        #else
        if isGridLayout {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(civitaiService.images) { image in
                    ImageFeedItemView(image: image, isGridMode: true)
                        .onAppear {
                            if image.id == civitaiService.images.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
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

    /// Filter (time + sort) menu, shown in the toolbar on both platforms.
    /// Matches UserContentView's menu.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
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

            Menu("Sort") {
                ForEach(FeedSort.allCases) { sort in
                    Button {
                        selectedSort = sort
                    } label: {
                        HStack {
                            Text(sort.displayName)
                            Spacer()
                            if sort == selectedSort {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: sort.icon)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter and sort")
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
