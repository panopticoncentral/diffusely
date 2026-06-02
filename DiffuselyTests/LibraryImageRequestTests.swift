import Testing
import Foundation
import Nuke
@testable import Diffusely
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct LibraryImageRequestTests {
    // A solid-color JPEG of the given pixel size, as encoded bytes.
    private func makeJPEG(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        #if canImport(UIKit)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
        #else
        let image = NSImage(size: size)
        image.lockFocus(); NSColor.red.setFill(); NSRect(origin: .zero, size: size).fill(); image.unlockFocus()
        return image.jpegData(compressionQuality: 0.9)!
        #endif
    }

    @Test func cacheKeyFoldsItemAndDimension() {
        #expect(LibraryImageRequest.cacheKey(itemID: 42, maxDimension: 600) == "library/42@600")
        #expect(LibraryImageRequest.cacheKey(itemID: 42, maxDimension: 1200) == "library/42@1200")
    }

    @Test func gridRequestUsesStableKeyAndKeepsDiskCache() {
        let req = LibraryImageRequest.request(
            itemID: 7, mediaFileName: "7.jpg", isVideo: false,
            maxDimension: LibraryImageRequest.gridDimension)
        #expect(req.imageId == "library/7@600")
        #expect(req.options.contains(.disableDiskCacheWrites) == false)
    }

    @Test func detailRequestDisablesDiskWrites() {
        let req = LibraryImageRequest.request(
            itemID: 7, mediaFileName: "7.jpg", isVideo: false,
            maxDimension: LibraryImageRequest.gridDimension + 600)
        #expect(req.options.contains(.disableDiskCacheWrites) == true)
    }

    @Test func thumbnailImageDownsamplesLocalImageFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lir-\(UUID().uuidString).jpg")
        try makeJPEG(width: 100, height: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(
            await LibraryImageRequest.thumbnailImage(localURL: url, isVideo: false, maxDimension: 32))
        #if canImport(UIKit)
        let maxSide = max(image.size.width * image.scale, image.size.height * image.scale)
        #else
        let maxSide = max(image.size.width, image.size.height)
        #endif
        #expect(maxSide <= 32)
    }
}
