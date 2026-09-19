import Testing
import Foundation
@testable import Diffusely

final class StubTagFeedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubTagFeedURLProtocol.handler else {
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

@Suite(.serialized) @MainActor struct CivitaiServiceTagFeedTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTagFeedURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func tagsFilterAppearsInRequestAndUsesDBPath() async throws {
        var capturedInput: String?
        StubTagFeedURLProtocol.handler = { request in
            capturedInput = request.url?.query?.removingPercentEncoding
            return (200, Data(#"[{"result":{"data":{"json":{"items":[],"nextCursor":null}}}}]"#.utf8))
        }
        defer { StubTagFeedURLProtocol.handler = nil }

        await makeService().fetchImages(videos: false, tags: [1234])

        let input = try #require(capturedInput)
        #expect(input.contains("\"tags\":[1234]"))
        // Tag feed must use the DB path, not the Meilisearch index.
        #expect(!input.contains("useIndex"))
    }

    @Test func noTagsKeyWhenFilterAbsent() async throws {
        var capturedInput: String?
        StubTagFeedURLProtocol.handler = { request in
            capturedInput = request.url?.query?.removingPercentEncoding
            return (200, Data(#"[{"result":{"data":{"json":{"items":[],"nextCursor":null}}}}]"#.utf8))
        }
        defer { StubTagFeedURLProtocol.handler = nil }

        await makeService().fetchImages(videos: false)

        let input = try #require(capturedInput)
        #expect(!input.contains("\"tags\""))
        #expect(input.contains("useIndex"))
    }
    @Test func refreshKeepsVisibleItemsOnFailureAndReplacesOnSuccess() async throws {
        let first = #"[{"result":{"data":{"json":{"items":[{"id":1,"url":"u1","width":1,"height":1,"nsfwLevel":1,"type":"image"}],"nextCursor":"page2"}}}}]"#
        StubTagFeedURLProtocol.handler = { _ in (200, Data(first.utf8)) }
        defer { StubTagFeedURLProtocol.handler = nil }
        let service = makeService()
        await service.fetchImages(videos: false)
        #expect(service.images.map(\.id) == [1])

        StubTagFeedURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await service.fetchImages(videos: false, replacing: true)
        #expect(service.images.map(\.id) == [1])
        #expect(service.error != nil)

        var paginatedAfterFailure = false
        StubTagFeedURLProtocol.handler = { _ in
            paginatedAfterFailure = true
            return (200, Data(first.utf8))
        }
        await service.loadMoreImages(videos: false)
        #expect(!paginatedAfterFailure)

        var requestInput: String?
        let next = #"[{"result":{"data":{"json":{"items":[{"id":2,"url":"u2","width":1,"height":1,"nsfwLevel":1,"type":"image"}],"nextCursor":null}}}}]"#
        StubTagFeedURLProtocol.handler = { request in
            requestInput = request.url?.query?.removingPercentEncoding
            return (200, Data(next.utf8))
        }
        await service.fetchImages(videos: false, replacing: true)
        #expect(service.images.map(\.id) == [2])
        #expect(service.error == nil)
        #expect(requestInput?.contains("page2") == false)

        // A terminal replacement page must clear the old pagination cursor.
        var requestedAnotherPage = false
        StubTagFeedURLProtocol.handler = { _ in
            requestedAnotherPage = true
            return (200, Data(next.utf8))
        }
        await service.loadMoreImages(videos: false)
        #expect(!requestedAnotherPage)
    }

}
