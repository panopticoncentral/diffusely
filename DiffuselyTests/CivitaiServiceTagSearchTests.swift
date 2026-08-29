import Testing
import Foundation
@testable import Diffusely

final class StubTagSearchURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubTagSearchURLProtocol.handler else {
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

/// `searchTags` backs the Add Tag sheet. Like `fetchVotableTags` it must decode
/// BOTH tRPC envelope formats (devalue string / legacy superjson) and degrade
/// to `[]` rather than throwing — the sheet shows "no results", not an alert.
@Suite(.serialized) @MainActor struct CivitaiServiceTagSearchTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTagSearchURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    private let superjsonEnvelope = #"[{"result":{"data":{"json":{"items":[{"id":4,"name":"anime"},{"id":9,"name":"animal"}]}}}}]"#

    @Test func sendsTheQueryToTagGetAll() async throws {
        var captured: URL?
        StubTagSearchURLProtocol.handler = { request in
            captured = request.url
            return (200, Data(#"[{"result":{"data":{"json":{"items":[]}}}}]"#.utf8))
        }
        defer { StubTagSearchURLProtocol.handler = nil }

        _ = await makeService().searchTags(query: "anime")

        let url = try #require(captured)
        #expect(url.path.hasSuffix("/tag.getAll"))
        let input = try #require(url.query?.removingPercentEncoding)
        #expect(input.contains("\"query\":\"anime\""))
    }

    @Test func decodesSuperjsonItems() async {
        let envelope = superjsonEnvelope
        StubTagSearchURLProtocol.handler = { _ in (200, Data(envelope.utf8)) }
        defer { StubTagSearchURLProtocol.handler = nil }

        let tags = await makeService().searchTags(query: "ani")

        #expect(tags == [CivitaiTag(id: 4, name: "anime"), CivitaiTag(id: 9, name: "animal")])
    }

    // Authentic devalue.stringify shape: `result.data` is a STRING.
    @Test func decodesDevalueItems() async {
        let envelope = #"[{"result":{"data":"[{\"items\":1},[2],{\"id\":3,\"name\":4},4,\"anime\"]"}}]"#
        StubTagSearchURLProtocol.handler = { _ in (200, Data(envelope.utf8)) }
        defer { StubTagSearchURLProtocol.handler = nil }

        let tags = await makeService().searchTags(query: "ani")

        #expect(tags == [CivitaiTag(id: 4, name: "anime")])
    }

    @Test func returnsEmptyOnServerError() async {
        StubTagSearchURLProtocol.handler = { _ in (500, Data("boom".utf8)) }
        defer { StubTagSearchURLProtocol.handler = nil }

        #expect(await makeService().searchTags(query: "anime").isEmpty)
    }

    /// A blank or whitespace-only query must not hit the network at all — the
    /// sheet clears its results instead of fetching the unfiltered tag list.
    @Test func blankQueryMakesNoRequest() async {
        var requestCount = 0
        StubTagSearchURLProtocol.handler = { _ in
            requestCount += 1
            return (200, Data(#"[{"result":{"data":{"json":{"items":[]}}}}]"#.utf8))
        }
        defer { StubTagSearchURLProtocol.handler = nil }

        let service = makeService()
        #expect(await service.searchTags(query: "   ").isEmpty)
        #expect(requestCount == 0)
    }

    @Test func dropsItemsWithoutAUsableId() async {
        let envelope = #"[{"result":{"data":{"json":{"items":[{"id":0,"name":"pending"},{"id":4,"name":"anime"}]}}}}]"#
        StubTagSearchURLProtocol.handler = { _ in (200, Data(envelope.utf8)) }
        defer { StubTagSearchURLProtocol.handler = nil }

        #expect(await makeService().searchTags(query: "ani") == [CivitaiTag(id: 4, name: "anime")])
    }
}
