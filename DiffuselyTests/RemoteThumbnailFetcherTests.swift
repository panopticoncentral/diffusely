import Testing
import Foundation
@testable import Diffusely
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct RemoteThumbnailFetcherTests {
    func jpegBytes() -> Data {
        let size = CGSize(width: 8, height: 8)
        #if canImport(UIKit)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.8)!
        #else
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.blue.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        return img.jpegData(compressionQuality: 0.8)!
        #endif
    }

    func response(_ code: Int, _ url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    @Test func returnsImageForValidJpeg() async {
        let data = jpegBytes()
        let fetcher = RemoteThumbnailFetcher { url in (data, self.response(200, url)) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image != nil)
    }

    @Test func returnsNilOnNon200() async {
        let fetcher = RemoteThumbnailFetcher { url in (Data(), self.response(404, url)) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image == nil)
    }

    @Test func returnsNilOnThrow() async {
        let fetcher = RemoteThumbnailFetcher { _ in throw URLError(.notConnectedToInternet) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image == nil)
    }

    @Test func returnsNilForGarbageBytes() async {
        let fetcher = RemoteThumbnailFetcher { url in (Data([0x00, 0x01]), self.response(200, url)) }
        let image = await fetcher.image(from: "https://example.com/x.jpeg", maxDimension: 600)
        #expect(image == nil)
    }
}
