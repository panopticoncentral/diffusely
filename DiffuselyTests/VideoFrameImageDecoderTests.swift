import Testing
import Foundation
@testable import Diffusely

@Suite struct VideoFrameImageDecoderTests {
    // ftyp box at bytes 4..<8 marks an MP4/QuickTime container.
    private func mp4Header() -> Data {
        var d = Data([0x00, 0x00, 0x00, 0x18]) // box size
        d.append(Data("ftypmp42".utf8))        // 'ftyp' + brand
        d.append(Data(repeating: 0, count: 8))
        return d
    }
    private func jpegHeader() -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) }

    @Test func detectsVideoByContentType() {
        #expect(VideoFrameImageDecoder.isVideo(contentType: "video/mp4", data: jpegHeader()))
        #expect(VideoFrameImageDecoder.isVideo(contentType: "VIDEO/MP4", data: jpegHeader()))
    }

    @Test func detectsVideoByMagicBytes() {
        #expect(VideoFrameImageDecoder.isVideo(contentType: nil, data: mp4Header()))
    }

    @Test func treatsImageAsNotVideo() {
        #expect(!VideoFrameImageDecoder.isVideo(contentType: "image/jpeg", data: jpegHeader()))
        #expect(!VideoFrameImageDecoder.isVideo(contentType: nil, data: jpegHeader()))
    }

    @Test func shortDataIsNotVideo() {
        #expect(!VideoFrameImageDecoder.isVideo(contentType: nil, data: Data([0x00, 0x01])))
    }
}
