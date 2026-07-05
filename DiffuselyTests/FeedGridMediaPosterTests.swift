import Testing
@testable import Diffusely

/// Regression guard for the Videos-grid stall (long spinners + "couldn't load /
/// retry"). The grid video poster must load the fast width=450 `.mp4`
/// (`detailURL`, ~0.15s TTFB, decoded to a frame by the registered
/// `VideoFrameImageDecoder`) — NOT `thumbnailURL`, whose
/// `transcode=true,anim=false,skip=4` CDN transform takes ~20s cold for feed
/// videos (which never carry an API `thumbnailUrl`), colliding with the image
/// pipeline's 20s request timeout.
@Suite struct FeedGridMediaPosterTests {
    private func makeImage(type: String) -> CivitaiImage {
        CivitaiImage(
            id: 42,
            url: "cf89b749-2427-4f5c-a59a-c4f440fb8ee5",
            width: 1280,
            height: 720,
            nsfwLevel: 1,
            type: type,
            postId: nil,
            user: nil,
            stats: nil
        )
    }

    @Test func videoPosterUsesFastDetailURLNotSlowThumbnail() {
        let video = makeImage(type: "video")
        let poster = FeedGridMedia.posterURL(for: video)
        #expect(poster == video.detailURL)
        #expect(poster != video.thumbnailURL)
        #expect(!poster.contains("skip=4"))
    }

    @Test func imagePosterUsesDetailURL() {
        let image = makeImage(type: "image")
        #expect(FeedGridMedia.posterURL(for: image) == image.detailURL)
    }
}
