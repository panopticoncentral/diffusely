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

    /// Gates the empty state so it can't flash on the first frame, before the
    /// initial `.task` load has had a chance to run.
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
                    .font(.largeTitle.bold())
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
                errorState(error)
            } else if civitaiService.images.isEmpty && !civitaiService.isLoading && hasLoadedOnce {
                emptyState
            }
        }
        .refreshable {
            await refreshImages()
        }
        .task {
            if civitaiService.images.isEmpty {
                await loadImages()
            }
            hasLoadedOnce = true
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

    private func errorState(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(videos ? "Couldn't Load Videos" : "Couldn't Load Images")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await refreshImages() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        // Push a full-screen error toward the center; an error appended below
        // existing content stays compact.
        .padding(.top, civitaiService.images.isEmpty ? 80 : 0)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: videos ? "video.slash" : "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(videos ? "No Videos" : "No Images")
                .font(.headline)
            Text("Try a different time period or pull to refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .padding(.top, 80)
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
