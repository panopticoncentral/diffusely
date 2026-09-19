import SwiftUI

/// A feed scoped to a single tag, opened by tapping a tag chip on a detail
/// view or a row in the Tags list. Modeled on `UserContentView`'s scoped-feed
/// pattern.
///
/// The media type is seeded by the caller — the type of the media the chip was
/// tapped from, or images when opened from the Tags list, which has no such
/// context — and is then switchable in the toolbar.
struct TagFeedView: View {
    @EnvironmentObject private var router: NavigationRouter
    @State private var focusedMediaID: Int?
    let tagId: Int
    let tagName: String

    @ObservedObject private var followedTags = FollowedTagsStore.shared
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
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ModeControl(title: "Media", selection: $videos) {
                    Text("Images").tag(false)
                    Text("Videos").tag(true)
                }
                ScrollView {
                    FeedFilterSummary(period: selectedPeriod, sort: selectedSort)
                    feedContent

                    if civitaiService.isLoading {
                        ProgressView()
                            .padding()
                    }

                    if let error = civitaiService.error {
                        FeedStatusView(videos: videos, error: error) { Task { await refreshContent() } }
                    } else if civitaiService.images.isEmpty && !civitaiService.isLoading && hasLoadedOnce {
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
                    Button {
                        if followedTags.isFollowing(id: tagId) {
                            followedTags.unfollow(id: tagId)
                        } else {
                            followedTags.follow(FollowedTag(id: tagId, name: tagName))
                        }
                    } label: {
                        Label(
                            followedTags.isFollowing(id: tagId) ? "Following" : "Follow Tag",
                            systemImage: followedTags.isFollowing(id: tagId) ? "checkmark" : "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    FeedFilterMenu(selectedPeriod: $selectedPeriod, selectedSort: $selectedSort)
                }
            }
            #if os(macOS)
                .focusedSceneValue(\.refreshFeed, RefreshFeedAction { Task { await refreshContent() } })
            #endif
            .task {
                await loadContent()
                hasLoadedOnce = true
            }
            .onChange(of: videos) { _, _ in
                civitaiService.clear()
                Task { await refreshContent() }
            }
            .onChange(of: selectedPeriod) { _, _ in
                Task { await refreshContent() }
            }
            .onChange(of: selectedSort) { _, _ in
                Task { await refreshContent() }
            }
            .onChange(of: domainManager.domain) { _, _ in
                civitaiService.clear()
                Task { await refreshContent() }
            }
            .onChange(of: focusedMediaID) {
                if let focusedMediaID { proxy.scrollTo(focusedMediaID, anchor: .center) }
            }
        }
    }

    /// Shared by macOS and regular-width iOS (iPad) so both get the same
    /// staggered wall of natural-aspect-ratio cells.
    private var masonryFeed: some View {
        MasonryGrid(
            items: civitaiService.images,
            aspectRatio: { ImageFeedItemView.displayAspectRatio(width: $0.width, height: $0.height) },
            onActivate: { router.push(.image($0)) }, onFocus: { focusedMediaID = $0 }
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

    private var emptyStateView: some View {
        FeedStatusView(videos: videos, error: nil) { Task { await refreshContent() } }
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
        await civitaiService.fetchImages(
            videos: videos, period: selectedPeriod, sort: selectedSort, tags: [tagId], replacing: true)
    }
}
