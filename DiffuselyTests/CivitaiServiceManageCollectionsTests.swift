import Testing
import Foundation
@testable import Diffusely

/// Dedicated URLProtocol for this suite so its global handler can't race with
/// `StubURLProtocol` (used by `CollectionListFetchTests`) when xcodebuild
/// distributes the two suites across parallel simulator clones. Both classes'
/// static `handler` properties are process-globals; using separate classes
/// gives each suite its own isolated handler.
final class StubManageCollectionsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubManageCollectionsURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized) @MainActor struct CivitaiServiceManageCollectionsTests {

    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubManageCollectionsURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    private func stubImage(id: Int) -> CivitaiImage {
        CivitaiImage(id: id, url: "u-\(id)", width: 1, height: 1,
                     nsfwLevel: 1, type: "image", postId: nil,
                     user: nil, stats: nil)
    }

    private func stubPost(id: Int) -> CivitaiPost {
        CivitaiPost(id: id, nsfwLevel: 1, title: nil, imageCount: 0,
                    user: CivitaiUser(id: 1, username: "a", image: nil),
                    stats: nil, images: [])
    }

    /// Sets a stub API key for the duration of the test and restores the
    /// previous value (if any) afterward. Mirrors the StubManageCollectionsURLProtocol.handler
    /// reset pattern.
    private func withStubAPIKey(_ body: () async throws -> Void) async rethrows {
        let previous = APIKeyManager.shared.apiKey
        APIKeyManager.shared.apiKey = "stub-test-key"
        defer { APIKeyManager.shared.apiKey = previous }
        try await body()
    }

    /// Extracts the JSON dictionary tRPC encodes as `?input={"0":{"json":{…}}}`.
    private func tRPCInput(from request: URLRequest) -> [String: Any]? {
        guard let url = request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let inputStr = comps.queryItems?.first(where: { $0.name == "input" })?.value,
              let data = inputStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zero = obj["0"] as? [String: Any],
              let json = zero["json"] as? [String: Any] else { return nil }
        return json
    }

    /// Decodes the POST body tRPC encodes as `{"0":{"json":{…}}}`.
    private func tRPCBody(from request: URLRequest) -> [String: Any]? {
        // URLSession strips httpBody when sending via URLProtocol; the body is
        // available on `httpBodyStream` instead.
        let stream: InputStream
        if let s = request.httpBodyStream {
            stream = s
        } else if let data = request.httpBody {
            return decode(data)
        } else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return decode(data)
    }

    private func decode(_ data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zero = obj["0"] as? [String: Any],
              let json = zero["json"] as? [String: Any] else { return nil }
        return json
    }

    @Test func getUserCollectionItemsByItemSendsImageIdAndDecodesIds() async throws {
        try await withStubAPIKey {
            let service = makeService()
            var capturedInput: [String: Any]?
            StubManageCollectionsURLProtocol.handler = { request in
                capturedInput = self.tRPCInput(from: request)
                let json = """
                [{"result":{"data":{"json":[
                    {"collectionId":10,"addedById":1,"tagId":null,"collection":{"userId":1,"read":"Private"},"canRemoveItem":true},
                    {"collectionId":20,"addedById":1,"tagId":null,"collection":{"userId":1,"read":"Private"},"canRemoveItem":true}
                ]}}}]
                """
                return (200, Data(json.utf8))
            }

            let ids = try await service.getUserCollectionItemsByItem(target: .image(stubImage(id: 99)))

            #expect(ids == [10, 20])
            #expect(capturedInput?["imageId"] as? Int == 99)
            #expect(capturedInput?["type"] as? String == "Image")
            #expect(capturedInput?["contributingOnly"] as? Bool == true)
            StubManageCollectionsURLProtocol.handler = nil
        }
    }

    @Test func getUserCollectionItemsByItemSendsPostIdForPostTarget() async throws {
        try await withStubAPIKey {
            let service = makeService()
            var capturedInput: [String: Any]?
            StubManageCollectionsURLProtocol.handler = { request in
                capturedInput = self.tRPCInput(from: request)
                return (200, Data("[{\"result\":{\"data\":{\"json\":[]}}}]".utf8))
            }

            _ = try await service.getUserCollectionItemsByItem(target: .post(stubPost(id: 77)))

            #expect(capturedInput?["postId"] as? Int == 77)
            #expect(capturedInput?["type"] as? String == "Post")
            StubManageCollectionsURLProtocol.handler = nil
        }
    }

    @Test func saveItemSendsCombinedAddAndRemoveLists() async throws {
        try await withStubAPIKey {
            let service = makeService()
            var capturedBody: [String: Any]?
            StubManageCollectionsURLProtocol.handler = { request in
                capturedBody = self.tRPCBody(from: request)
                return (200, Data("[{\"result\":{\"data\":{\"json\":{\"status\":\"updated\"}}}}]".utf8))
            }

            try await service.saveItem(
                target: .image(stubImage(id: 50)),
                adding: [101, 102],
                removing: [200]
            )

            #expect(capturedBody?["imageId"] as? Int == 50)
            #expect(capturedBody?["type"] as? String == "Image")
            let collections = capturedBody?["collections"] as? [[String: Any]]
            #expect(collections?.count == 2)
            #expect(collections?.compactMap { $0["collectionId"] as? Int }.sorted() == [101, 102])
            #expect((capturedBody?["removeFromCollectionIds"] as? [Int])?.sorted() == [200])
            StubManageCollectionsURLProtocol.handler = nil
        }
    }

    @Test func saveItemSendsPostIdForPostTarget() async throws {
        try await withStubAPIKey {
            let service = makeService()
            var capturedBody: [String: Any]?
            StubManageCollectionsURLProtocol.handler = { request in
                capturedBody = self.tRPCBody(from: request)
                return (200, Data("[{\"result\":{\"data\":{\"json\":{\"status\":\"added\"}}}}]".utf8))
            }

            try await service.saveItem(
                target: .post(stubPost(id: 33)),
                adding: [42],
                removing: []
            )

            #expect(capturedBody?["postId"] as? Int == 33)
            #expect(capturedBody?["type"] as? String == "Post")
            #expect((capturedBody?["removeFromCollectionIds"] as? [Int])?.isEmpty == true)
            StubManageCollectionsURLProtocol.handler = nil
        }
    }
}
