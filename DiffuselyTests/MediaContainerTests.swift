import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Diffusely

@Suite struct MediaContainerTests {
    @Test func detectsPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        #expect(MediaContainer.detect(png) == .png)
        #expect(MediaContainer.png.fileExtension == "png")
        #expect(MediaContainer.png.utType == .png)
    }

    @Test func detectsJPEG() {
        #expect(MediaContainer.detect(Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 0])) == .jpeg)
        #expect(MediaContainer.jpeg.utType == .jpeg)
    }

    @Test func detectsWebP() {
        var riff = Data("RIFF".utf8)
        riff.append(contentsOf: [0, 0, 0, 0])
        riff.append(Data("WEBP".utf8))
        #expect(MediaContainer.detect(riff) == .webp)
        #expect(MediaContainer.webp.utType == .webP)
    }

    @Test func otherForShortOrUnknownBytes() {
        #expect(MediaContainer.detect(Data()) == .other)
        #expect(MediaContainer.detect(Data([0x00, 0x01, 0x02])) == .other)
        #expect(MediaContainer.detect(Data("RIFF....WAVE".utf8)) == .other)
        #expect(MediaContainer.other.utType == .data)
    }
}
