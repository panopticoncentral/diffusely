import Testing
import Foundation
@testable import Diffusely

@Suite struct ExifUserCommentDecoderTests {
    private func header(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(Data(repeating: 0, count: 8 - d.count))
        return d
    }

    @Test func decodesASCIIHeader() {
        let bytes = header("ASCII") + Data("hello".utf8)
        #expect(ExifUserCommentDecoder.decode(bytes) == "hello")
    }

    @Test func decodesUTF8Header() {
        let bytes = header("UTF8") + Data("héllo".utf8)
        #expect(ExifUserCommentDecoder.decode(bytes) == "héllo")
    }

    @Test func decodesUnicodeBigEndianWithBOM() {
        var bytes = header("UNICODE")
        bytes.append(contentsOf: [0xFE, 0xFF])
        bytes.append("hi".data(using: .utf16BigEndian)!)
        #expect(ExifUserCommentDecoder.decode(bytes) == "hi")
    }

    @Test func decodesUnicodeLittleEndianWithBOM() {
        var bytes = header("UNICODE")
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append("hi".data(using: .utf16LittleEndian)!)
        #expect(ExifUserCommentDecoder.decode(bytes) == "hi")
    }

    @Test func decodesUnicodeWithoutBOMAsBigEndian() {
        let bytes = header("UNICODE") + "{\"a\":1}".data(using: .utf16BigEndian)!
        #expect(ExifUserCommentDecoder.decode(bytes) == "{\"a\":1}")
    }

    @Test func stripsTrailingNulsAndRejectsShortInput() {
        let bytes = header("ASCII") + Data("x\0\0".utf8)
        #expect(ExifUserCommentDecoder.decode(bytes) == "x")
        #expect(ExifUserCommentDecoder.decode(Data([1, 2, 3])) == nil)
    }

    @Test func scannerFindsUserCommentInRealJPEG() throws {
        let url = try EmbeddedMetadataReaderTests.makeJPEGWithUserComment("scan me")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let raw = try #require(JPEGExifScanner.userCommentBytes(in: data))
        #expect(ExifUserCommentDecoder.decode(raw) == "scan me")
    }

    @Test func scannerReturnsNilForNonJPEGOrNoExif() {
        #expect(JPEGExifScanner.userCommentBytes(in: Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(JPEGExifScanner.userCommentBytes(in: Data([0xFF, 0xD8, 0xFF, 0xD9])) == nil)
    }
}
