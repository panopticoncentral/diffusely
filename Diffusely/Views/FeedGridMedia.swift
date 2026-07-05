import SwiftUI

/// The media layer of a grid cell: a still poster by default, with an on-demand
/// video preview. Sized by the caller (`width`×`height`) so the hover swap never
/// reflows. macOS: hovering a video past HoverIntent's delay fades in a muted,
/// looping preview; un-hovering removes it (pausing the cached player). iOS: no
/// hover — the poster stays and the caller's tap opens the detail view.
struct FeedGridMedia: View {
    let image: CivitaiImage
    let width: CGFloat
    let height: CGFloat
    /// Runs when the cell is tapped/clicked (opens detail). Attached to the same
    /// view as `.onHover` so a covering tap layer can't suppress hover tracking.
    var onTap: () -> Void = {}

    #if os(macOS)
    @StateObject private var hover = HoverIntent()
    #endif

    var body: some View {
        ZStack {
            poster

            #if os(macOS)
            if image.isVideo && hover.isArmed {
                CachedVideoPlayer(
                    url: image.detailURL,
                    autoPlay: true,
                    isMuted: true,
                    showsLoadingPlaceholder: false
                )
                .frame(width: width, height: height)
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            #endif
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        #if os(macOS)
        .animation(.easeInOut(duration: 0.2), value: hover.isArmed)
        .onHover { hovering in
            guard image.isVideo else { return }
            if hovering { hover.begin() } else { hover.cancel() }
        }
        .onDisappear { hover.cancel() }
        #endif
    }

    /// The URL to load as the still poster for a cell. For BOTH images and
    /// videos this is `detailURL`: a still JPEG for images, and the small
    /// `transcode=true,width=450` `.mp4` for videos — which the app's registered
    /// `VideoFrameImageDecoder` turns into a frame. We deliberately do NOT use
    /// `thumbnailURL` for videos: feed videos never carry an API `thumbnailUrl`,
    /// so it falls back to a `transcode=true,anim=false,skip=4` frame extraction
    /// that takes ~20s cold and collides with the image pipeline's 20s request
    /// timeout — the cause of the Videos-grid spinners / "couldn't load" stalls.
    /// `detailURL` returns in ~0.15s and is the same URL hover playback warms.
    static func posterURL(for image: CivitaiImage) -> String {
        image.detailURL
    }

    @ViewBuilder
    private var poster: some View {
        let url = Self.posterURL(for: image)
        if image.isVideo {
            // A video still requires video bytes; `VideoPosterView` extracts the
            // frame from the remote mp4 with a small ranged fetch instead of
            // downloading the whole file through Nuke.
            VideoPosterView(url: url, width: width, height: height)
        } else {
            CachedAsyncImage(url: url)
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        }
    }
}
