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
}
