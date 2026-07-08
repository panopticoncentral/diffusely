import SwiftUI

/// Horizontally paged media viewer shared by `PostDetailView` (a post's
/// images) and `ImageDetailView` (a feed slice, for next/previous browsing).
///
/// iOS pages with a `TabView`; macOS uses a paged horizontal `ScrollView`
/// because the default TabView style on macOS renders one tab button per
/// image at the top, which clashes with the dot indicator. Left/right arrow
/// keys page on both platforms; focus is seeded automatically so arrows work
/// without a prior click.
///
/// macOS position uses a clean read/write split: arrow keys *write* via
/// `ScrollViewReader.scrollTo`, while the visible page is *read* back from
/// the live scroll offset via `onScrollGeometryChange`. A `.scrollPosition(id:)`
/// two-way binding never wrote back on a Magic Mouse swipe, so the dot
/// indicator stayed frozen on the first image.
struct MediaCarousel<CellMenu: View>: View {
    let images: [CivitaiImage]
    @Binding var currentIndex: Int
    /// Height available to the carousel (the enclosing window/screen height);
    /// on macOS the carousel claims exactly this so media fits without
    /// scrolling, on iOS it renders at a fixed ideal height in the scroll flow.
    let maxHeight: CGFloat
    /// Context-menu items attached to each media cell (right-click /
    /// long-press). Only the visible cell can be targeted, so callers can use
    /// their current-image state inside.
    @ViewBuilder var cellMenu: () -> CellMenu

    @FocusState private var focused: Bool

    #if os(macOS)
    /// The page to open on (the tapped cell). The paged `ScrollView` starts
    /// pinned at offset 0, so we scroll here on appear; captured once at init
    /// because the read-back below rewrites `currentIndex`.
    @State private var initialIndex: Int
    /// Gate: ignore the read-back until the initial jump to `initialIndex`
    /// lands, otherwise the first offset-0 geometry read clobbers `currentIndex`
    /// back to 0 (the reported bug — opening any non-first image showed image 1).
    @State private var didInitialScroll = false

    init(
        images: [CivitaiImage],
        currentIndex: Binding<Int>,
        maxHeight: CGFloat,
        @ViewBuilder cellMenu: @escaping () -> CellMenu
    ) {
        self.images = images
        self._currentIndex = currentIndex
        self.maxHeight = maxHeight
        self.cellMenu = cellMenu
        self._initialIndex = State(initialValue: currentIndex.wrappedValue)
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                #if os(macOS)
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        // Eager HStack (not Lazy): the paged scroller needs
                        // every cell's width measured up front so the content
                        // is genuinely wider than the viewport. With a
                        // LazyHStack on macOS the unrealized cells collapse the
                        // content width, so neither trackpad/Magic Mouse swipes
                        // nor scrollTo had anywhere to scroll — the carousel
                        // stayed pinned on the first image. Autoplay is gated to
                        // the active cell so eager rendering doesn't start every
                        // video at once.
                        HStack(spacing: 0) {
                            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                                mediaCell(for: image, maxHeight: geometry.size.height, isActive: index == currentIndex)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .focusable()
                    .focused($focused)
                    .onKeyPress(.leftArrow) { scroll(to: currentIndex - 1, using: scrollProxy); return .handled }
                    .onKeyPress(.rightArrow) { scroll(to: currentIndex + 1, using: scrollProxy); return .handled }
                    .onScrollGeometryChange(for: Int.self) { geo in
                        // Round the leading content offset to the nearest
                        // page so the read-back follows the snap, whether the
                        // page change came from a swipe or arrow scrollTo.
                        let pageWidth = geo.containerSize.width
                        guard pageWidth > 0 else { return currentIndex }
                        return Int((geo.contentOffset.x / pageWidth).rounded())
                    } action: { _, page in
                        let clamped = max(0, min(page, images.count - 1))
                        guard didInitialScroll else {
                            // Start tracking only once we've settled on the
                            // tapped image; earlier offset-0 reads are the
                            // pre-scroll layout and must not overwrite it.
                            if clamped == initialIndex { didInitialScroll = true }
                            return
                        }
                        if clamped != currentIndex { currentIndex = clamped }
                    }
                    .onAppear {
                        // Jump to the tapped image. Non-animated so it's in place
                        // before the first paint.
                        if initialIndex > 0 {
                            scrollProxy.scrollTo(initialIndex, anchor: .center)
                        }
                    }
                    .task {
                        // Re-assert the position a tick later in case the eager
                        // layout wasn't measured on the first onAppear attempt.
                        if initialIndex > 0 && !didInitialScroll {
                            try? await Task.sleep(for: .milliseconds(50))
                            if !didInitialScroll {
                                scrollProxy.scrollTo(initialIndex, anchor: .center)
                            }
                        }
                        // Safety net: enable swipe/scroll tracking even if the
                        // settle read never matched (e.g. a fractional offset).
                        try? await Task.sleep(for: .milliseconds(400))
                        didInitialScroll = true
                    }
                    .overlay(alignment: .bottom) {
                        // Float the indicator inside the carousel (which fills
                        // the window on macOS) so it's visible without
                        // scrolling. Capsule with a material backing keeps the
                        // dots legible over any image content beneath them.
                        pageIndicator
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
                #else
                TabView(selection: $currentIndex) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        mediaCell(for: image, maxHeight: geometry.size.height)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .focusable()
                .focused($focused)
                .onKeyPress(.leftArrow) { advance(by: -1); return .handled }
                .onKeyPress(.rightArrow) { advance(by: 1); return .handled }
                #endif
            }
            #if os(macOS)
            .frame(height: maxHeight)
            #else
            .frame(minHeight: 400, idealHeight: 500)
            #endif

            // iOS: dots sit below the carousel (the carousel has a fixed
            // idealHeight so there's room). On macOS the carousel claims the
            // full window height, so the dots float as an overlay above.
            #if os(iOS)
            pageIndicator
                .padding(.vertical, 12)
            #endif
        }
        .task {
            // Seed keyboard focus so arrow keys work without a prior click.
            // Detail views fill the screen and have no competing focusables.
            focused = true
        }
    }

    /// Row of small dots showing which image is currently visible.
    @ViewBuilder
    private var pageIndicator: some View {
        if images.count > 1 {
            HStack(spacing: 6) {
                ForEach(0..<images.count, id: \.self) { index in
                    Circle()
                        .fill(currentIndex == index ? Color.primary : Color.primary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Image \(currentIndex + 1) of \(images.count)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: advance(by: 1)
                case .decrement: advance(by: -1)
                @unknown default: break
                }
            }
        }
    }

    /// Renders a single cell sized to the available height, picking video vs
    /// image based on the media type. Videos autoplay muted (only when their
    /// page is active); still images get the zoomable wrapper.
    @ViewBuilder
    private func mediaCell(for image: CivitaiImage, maxHeight: CGFloat, isActive: Bool = true) -> some View {
        let aspectRatio = ImageFeedItemView.displayAspectRatio(width: image.width, height: image.height)
        Group {
            if image.isVideo {
                CachedVideoPlayer(
                    url: image.detailURL,
                    autoPlay: isActive,
                    isMuted: true
                )
                .aspectRatio(aspectRatio, contentMode: .fit)
                .detailMediaFrame(maxHeight: maxHeight)
            } else {
                ZoomableView {
                    CachedAsyncImage(
                        url: image.detailURL,
                        expectedAspectRatio: aspectRatio
                    )
                    .aspectRatio(contentMode: .fit)
                }
                .detailMediaFrame(maxHeight: maxHeight)
            }
        }
        .contextMenu { cellMenu() }
    }

    /// Clamped step through the images — arrow keys and the accessibility
    /// adjustable action. withAnimation keeps the page transition smooth on
    /// the iOS TabView.
    private func advance(by delta: Int) {
        let count = images.count
        guard count > 0 else { return }
        let next = max(0, min(currentIndex + delta, count - 1))
        guard next != currentIndex else { return }
        withAnimation { currentIndex = next }
    }

    #if os(macOS)
    /// Arrow-key navigation for the macOS carousel: clamp to range, then
    /// scroll the paged ScrollView to that page. currentIndex is *not* set
    /// here — the onScrollGeometryChange read-back updates it once the scroll
    /// settles, which keeps the dot indicator and per-image metadata loads
    /// following the snap regardless of whether the page changed via swipe or
    /// arrow key.
    private func scroll(to index: Int, using proxy: ScrollViewProxy) {
        let clamped = max(0, min(index, images.count - 1))
        guard clamped != currentIndex else { return }
        withAnimation { proxy.scrollTo(clamped, anchor: .center) }
    }
    #endif
}
