import Testing
import Foundation
@testable import Diffusely

final class StubDevalueFeedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubDevalueFeedURLProtocol.handler else {
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

/// End-to-end regression for the Civitai devalue flip: `fetchImages` must decode
/// BOTH the new devalue response (`result.data` is a STRING) and the legacy
/// superjson one (`result.data` is `{ json: … }`) — a stale pool can still write
/// superjson, so the union READ has to accept either.
@Suite(.serialized) @MainActor struct CivitaiServiceDevalueFeedTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDevalueFeedURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    // Authentic devalue.stringify(v5.8.1) bytes: two images sharing one `user`
    // object (deduped by devalue), nextCursor "20|123".
    private let devalueEnvelope = #"[{"result":{"data":"[{\"nextCursor\":1,\"items\":2,\"source\":20},\"20|123\",[3,14],{\"id\":4,\"url\":5,\"width\":6,\"height\":7,\"nsfwLevel\":4,\"type\":8,\"postId\":9,\"user\":10,\"stats\":13},1,\"uuid-1\",10,20,\"image\",100,{\"id\":11,\"username\":12,\"image\":13},5,\"alice\",null,{\"id\":15,\"url\":16,\"width\":17,\"height\":18,\"nsfwLevel\":19,\"type\":8,\"postId\":9,\"user\":10,\"stats\":13},2,\"uuid-2\",30,40,4,0]"}}]"#

    @Test func fetchImagesDecodesDevalueResponse() async throws {
        let envelope = devalueEnvelope
        StubDevalueFeedURLProtocol.handler = { _ in (200, Data(envelope.utf8)) }
        defer { StubDevalueFeedURLProtocol.handler = nil }

        let service = makeService()
        await service.fetchImages(videos: false)

        #expect(service.error == nil)
        #expect(service.images.count == 2)
        #expect(service.images.first?.id == 1)
        #expect(service.images.last?.id == 2)
        #expect(service.images.first?.user?.username == "alice")
    }

    @Test func fetchImagesStillDecodesSuperjsonResponse() async throws {
        let superjson = #"[{"result":{"data":{"json":{"nextCursor":null,"items":[{"id":7,"url":"u7","width":1,"height":2,"nsfwLevel":1,"type":"image","postId":null,"user":null,"stats":null}]}}}}]"#
        StubDevalueFeedURLProtocol.handler = { _ in (200, Data(superjson.utf8)) }
        defer { StubDevalueFeedURLProtocol.handler = nil }

        let service = makeService()
        await service.fetchImages(videos: false)

        #expect(service.error == nil)
        #expect(service.images.count == 1)
        #expect(service.images.first?.id == 7)
    }
}
