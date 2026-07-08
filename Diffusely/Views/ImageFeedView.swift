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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let videos: Bool

    // Each media type owns its own filter, persisted per type. Images and Videos
    // previously shared one period/sort pair, so changing the sort in one silently
    // changed (and refreshed) the other; the state was also non-persistent, so it
    // reset to Week / Most Reactions every launch. Keying @AppStorage by media
    // type fixes both.
    @AppStorage private var selectedPeriod: Timeframe
    @AppStorage private var selectedSort: FeedSort

    init(videos: Bool) {
        self.videos = videos
        let suffix = videos ? "videos" : "images"
        _selectedPeriod = AppStorage(wrappedValue: .week, "feedPeriod.\(suffix)")
        _selectedSort = AppStorage(wrappedValue: .mostReactions, "feedSort.\(suffix)")
    }

    /// Gates the empty state so it can't flash on the first frame, before the
    /// initial `.task` load has had a chance to run.
    @State private var hasLoadedOnce = false

    #if os(iOS)
    @State private var showingSettings = false
    #endif

    #if os(macOS)
    /// Roaming keyboard focus over the feed (index into `civitaiService.images`).
    /// Linear next/prev — the masonry fills column-major, so there's no clean 2-D.
    @State private var focusedIndex: Int?
    @EnvironmentObject private var router: NavigationRouter
    #endif

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
        // Real navigation bar (the tab's NavigationStack provides it): large
        // title that collapses on scroll and scroll-edge material for free,
        // replacing the old hand-rolled largeTitle header.
        feedScroll
            .navigationTitle(videos ? "Videos" : "Images")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FeedFilterMenu(
                        selectedPeriod: $selectedPeriod,
                        selectedSort: $selectedSort
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        #endif
    }

    private var feedScroll: some View {
        ScrollViewReader { proxy in
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
            #if os(macOS)
            // Arrow keys move a focus ring through the feed; Return opens the
            // focused image (same paged detail as a click).
            .gridKeyboardNavigation(
                count: civitaiService.images.count,
                columns: 1,
                focusedIndex: $focusedIndex,
                onActivate: { openFeedItem($0) }
            )
            .onChange(of: focusedIndex) { scrollFeedItemIntoView(using: proxy) }
            #endif
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
                preserveAspectRatio: true,
                feedImages: civitaiService.images,
                showsContextMenu: true,   // macOS: native right-click verbs on feed cells
                keyboardFocused: image.id == focusedFeedImageID
            )
                .onAppear { maybeLoadMore(for: image) }
        }
        #else
        if isGridLayout {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(civitaiService.images, id: \.id) { image in
                    ImageFeedItemView(image: image, isGridMode: true, feedImages: civitaiService.images)
                        .onAppear { maybeLoadMore(for: image) }
                }
            }
            .padding(.horizontal, 2)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(civitaiService.images, id: \.id) { image in
                    ImageFeedItemView(image: image, isGridMode: false, feedImages: civitaiService.images)
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
            #if os(macOS)
            Text("Try a different time period, or press ⌘R to refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #else
            Text("Try a different time period or pull to refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
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

    #if os(macOS)
    /// id of the keyboard-focused feed cell, for its ring.
    private var focusedFeedImageID: Int? {
        guard let focusedIndex, civitaiService.images.indices.contains(focusedIndex) else { return nil }
        return civitaiService.images[focusedIndex].id
    }

    /// Return opens the focused image with the same paged detail a click gives.
    private func openFeedItem(_ index: Int) {
        let images = civitaiService.images
        guard images.indices.contains(index) else { return }
        router.push(.browse(images: images, index: index))
    }

    private func scrollFeedItemIntoView(using proxy: ScrollViewProxy) {
        guard let focusedIndex, civitaiService.images.indices.contains(focusedIndex) else { return }
        proxy.scrollTo(civitaiService.images[focusedIndex].id, anchor: .center)
    }
    #endif

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
