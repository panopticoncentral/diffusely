import Testing
import Foundation
@testable import Diffusely

@Suite struct CivitaiVotableTagTests {
    @Test func decodesTagObjectIgnoringExtraKeys() throws {
        let json = Data(#"""
        {"id":4,"name":"anime","type":"Label","nsfwLevel":1,"score":42,"upVotes":50,"downVotes":8,"automated":true}
        """#.utf8)

        let tag = try JSONDecoder().decode(CivitaiVotableTag.self, from: json)

        #expect(tag.id == 4)
        #expect(tag.name == "anime")
        #expect(tag.type == "Label")
        #expect(tag.nsfwLevel == 1)
        #expect(tag.score == 42)
    }

    @Test func decodesArray() throws {
        let json = Data(#"""
        [{"id":4,"name":"anime","type":"Label","nsfwLevel":1,"score":42},
         {"id":5,"name":"nudity","type":"Moderation","nsfwLevel":4,"score":10}]
        """#.utf8)

        let tags = try JSONDecoder().decode([CivitaiVotableTag].self, from: json)

        #expect(tags.count == 2)
        #expect(tags[1].name == "nudity")
    }
}

/// Dedicated URLProtocol stub for the votable-tags suite so its handler can't
/// race with stubs other suites install. Mirrors the StubURLProtocol pattern
/// used across the service test suites.
final class StubVotableTagsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubVotableTagsURLProtocol.handler else {
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

@Suite(.serialized) @MainActor struct FetchVotableTagsTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubVotableTagsURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func ordersModerationFirstThenByScore() async {
        StubVotableTagsURLProtocol.handler = { _ in
            (200, Data(#"""
            [{"result":{"data":{"json":[
              {"id":4,"name":"anime","type":"Label","nsfwLevel":1,"score":90},
              {"id":5,"name":"nudity","type":"Moderation","nsfwLevel":4,"score":3},
              {"id":6,"name":"forest","type":"Label","nsfwLevel":1,"score":50}
            ]}}}]
            """#.utf8))
        }
        defer { StubVotableTagsURLProtocol.handler = nil }

        let tags = await makeService().fetchVotableTags(imageId: 1)

        #expect(tags.map(\.name) == ["nudity", "anime", "forest"])
    }

    @Test func dropsNonFilterableTags() async {
        StubVotableTagsURLProtocol.handler = { _ in
            (200, Data(#"""
            [{"result":{"data":{"json":[
              {"id":0,"name":"pending","type":"UserGenerated","nsfwLevel":1,"score":1},
              {"id":7,"name":"keep","type":"Label","nsfwLevel":1,"score":1}
            ]}}}]
            """#.utf8))
        }
        defer { StubVotableTagsURLProtocol.handler = nil }

        let tags = await makeService().fetchVotableTags(imageId: 1)

        #expect(tags.map(\.name) == ["keep"])
    }

    @Test func returnsEmptyOnServerError() async {
        StubVotableTagsURLProtocol.handler = { _ in (500, Data("error".utf8)) }
        defer { StubVotableTagsURLProtocol.handler = nil }

        let tags = await makeService().fetchVotableTags(imageId: 1)

        #expect(tags.isEmpty)
    }
}
