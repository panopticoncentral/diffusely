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

    @Test(arguments: [false, true])
    func paginationContinuesPastUnknownDimensions(devalue: Bool) async throws {
        let first = #"[{"result":{"data":{"json":{"nextCursor":"feed:4:1","items":[{"id":1,"url":"u1","width":100,"height":200,"nsfwLevel":1,"type":"image"}]}}}}]"#
        // Reduced reproduction of the live Today / Most Collected response:
        // a null dimension must not prevent decoding the page and its cursor.
        let second: String
        if devalue {
            second = #"[{"result":{"data":"[{\"nextCursor\":1,\"items\":2},\"feed:3:2\",[3],{\"id\":4,\"url\":5,\"width\":6,\"height\":6,\"nsfwLevel\":7,\"type\":8},2,\"u2\",null,1,\"image\"]"}}]"#
        } else {
            second = #"[{"result":{"data":{"json":{"nextCursor":"feed:3:2","items":[{"id":2,"url":"u2","width":null,"height":null,"nsfwLevel":1,"type":"image"}]}}}}]"#
        }
        let third = #"[{"result":{"data":{"json":{"nextCursor":null,"items":[{"id":3,"url":"u3","width":300,"height":400,"nsfwLevel":1,"type":"image"}]}}}}]"#
        var requestCount = 0
        StubDevalueFeedURLProtocol.handler = { request in
            let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let input = try #require(components.queryItems?.first { $0.name == "input" }?.value)
            let batch = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: [String: [String: Any]]])
            let parameters = try #require(batch["0"]?["json"])
            #expect(parameters["period"] as? String == "Day")
            #expect(parameters["sort"] as? String == "Most Collected")
            #expect(parameters["useIndex"] as? Bool == true)
            requestCount += 1
            switch requestCount {
            case 1:
                #expect(parameters["cursor"] == nil)
                return (200, Data(first.utf8))
            case 2:
                #expect(parameters["cursor"] as? String == "feed:4:1")
                return (200, Data(second.utf8))
            default:
                #expect(parameters["cursor"] as? String == "feed:3:2")
                return (200, Data(third.utf8))
            }
        }
        defer { StubDevalueFeedURLProtocol.handler = nil }

        let service = makeService()
        await service.fetchImages(videos: false, period: .day, sort: .mostCollected)
        await service.loadMoreImages(videos: false, period: .day, sort: .mostCollected)
        #expect(service.error == nil)
        #expect(service.images.map(\.id) == [1, 2])
        let unknownSize = try #require(service.images.last)
        #expect(unknownSize.width == 0)
        #expect(unknownSize.height == 0)

        await service.loadMoreImages(videos: false, period: .day, sort: .mostCollected)
        #expect(service.error == nil)
        #expect(service.images.map(\.id) == [1, 2, 3])
        #expect(service.images.last?.width == 300)
        #expect(service.images.last?.height == 400)
        await service.loadMoreImages(videos: false, period: .day, sort: .mostCollected)
        #expect(requestCount == 3)
    }

    @Test(arguments: [
        #""#,
        #", "width": null, "height": 200"#,
        #", "width": 100, "height": null"#
    ])
    func missingDimensionsUseLayoutFallback(dimensions: String) throws {
        let json = #"{"id":1,"url":"u1","nsfwLevel":1,"type":"image"\#(dimensions)}"#
        let image = try JSONDecoder().decode(CivitaiImage.self, from: Data(json.utf8))
        #expect(image.width == (dimensions.contains("100") ? 100 : 0))
        #expect(image.height == (dimensions.contains("200") ? 200 : 0))
        let ratio = ImageFeedItemView.displayAspectRatio(width: image.width, height: image.height)
        #expect(ratio.isFinite && ratio > 0)
        let roundTrip = try JSONDecoder().decode(CivitaiImage.self, from: JSONEncoder().encode(image))
        #expect(roundTrip == image)
    }
}
