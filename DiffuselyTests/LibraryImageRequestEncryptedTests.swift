import XCTest
import CryptoKit
import ImageIO
@testable import Diffusely

final class LibraryImageRequestEncryptedTests: XCTestCase {
    func testDecryptedMediaDataReadsEncryptedBlob() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])   // stub bytes
        try store.writeMedia(jpeg, itemID: 3, plaintextExtension: "jpeg")
        XCTAssertEqual(LibraryImageRequest.decryptedMediaData(itemID: 3, store: store), jpeg)
    }

    func testCDNImagePreviewsDoNotRequireEncryptedOriginal() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.itemsDirectory) }
        try writeMetadata(store: store, isVideo: false)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        for dimension: CGFloat in [600, 2048] {
            let data = try await LibraryImageRequest.loadEncryptedBytes(
                itemID: 3, isVideo: false, maxDimension: dimension, store: store, session: session)
            XCTAssertEqual(String(data: data, encoding: .utf8),
                "https://cdn.example/bucket/synthetic/anim=false,width=\(Int(dimension)),optimized=true/3.jpeg")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(itemID: 3, plaintextExtension: "jpeg").path))
    }

    func testCDNVideoPosterDoesNotRequireEncryptedVideo() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.itemsDirectory) }
        try writeMetadata(store: store, isVideo: true)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let data = try await LibraryImageRequest.loadEncryptedBytes(
            itemID: 3, isVideo: true, maxDimension: 600, store: store, session: session)
        XCTAssertEqual(String(data: data, encoding: .utf8),
            "https://cdn.example/bucket/synthetic/transcode=true,anim=false,skip=4,width=600/3.jpeg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(itemID: 3, plaintextExtension: "mp4").path))
    }

    func testMissingCDNImageFallsBackToEncryptedOriginal() async throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.itemsDirectory) }
        try writeMetadata(store: store, isVideo: false, host: "missing.example")

        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let original = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(original, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try store.writeMedia(original as Data, itemID: 3, plaintextExtension: "jpeg")
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let data = try await LibraryImageRequest.loadEncryptedBytes(
            itemID: 3, isVideo: false, maxDimension: 600, store: store, session: session)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
    }

    private func makeStore() throws -> LibraryFileStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
    }

    private func writeMetadata(store: LibraryFileStore, isVideo: Bool, host: String = "cdn.example") throws {
        let ext = isVideo ? "mp4" : "jpeg"
        let metadata = LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: 3,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://example.com/images/3", sourceDomain: "example.com",
            originalCDNURL: "https://\(host)/bucket/synthetic/original=true/3.\(ext)",
            mediaType: isVideo ? .video : .image, mediaFileName: "3.\(ext)",
            fileByteSize: 10, contentSHA256: "synthetic", width: 2, height: 2, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: [], savedAt: Date(), savedByAppVersion: "test")
        try store.writeMetadata(LibraryItemMetadata.encoder().encode(metadata), itemID: 3)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryThumbnailURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Returns the requested URL as sentinel bytes, or a 404, without network I/O.
private final class LibraryThumbnailURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: url.host == "missing.example" ? 404 : 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(url.absoluteString.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
