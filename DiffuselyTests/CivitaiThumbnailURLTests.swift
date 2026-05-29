import Testing
import Foundation
@testable import Diffusely

@Suite struct CivitaiThumbnailURLTests {
    let original = "https://image.civitai.com/abc/uuid-123/original=true/999.jpeg"
    let originalVideo = "https://image.civitai.com/abc/uuid-123/original=true/999.mp4"

    @Test func imageURLSwapsTransformAndKeepsJpeg() {
        let url = CivitaiThumbnailURL.thumbnail(fromOriginal: original, isVideo: false, width: 600)
        #expect(url == "https://image.civitai.com/abc/uuid-123/anim=false,width=600,optimized=true/999.jpeg")
    }

    @Test func videoURLRequestsStaticFrameAsJpeg() {
        let url = CivitaiThumbnailURL.thumbnail(fromOriginal: originalVideo, isVideo: true, width: 600)
        #expect(url == "https://image.civitai.com/abc/uuid-123/transcode=true,anim=false,skip=4,width=600/999.jpeg")
    }

    @Test func returnsNilForUnexpectedShape() {
        #expect(CivitaiThumbnailURL.thumbnail(fromOriginal: "https://example.com/foo.jpeg", isVideo: false, width: 600) == nil)
        #expect(CivitaiThumbnailURL.thumbnail(fromOriginal: "garbage", isVideo: false, width: 600) == nil)
    }
}
