import Testing
import Foundation
@testable import Diffusely

/// Dedicated URLProtocol for this suite so its handler can't race with the
/// stubs other suites install. Mirrors the StubURLProtocol pattern used in
/// CollectionListFetchTests.
final class StubUserByIdURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubUserByIdURLProtocol.handler else {
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

@Suite(.serialized) @MainActor struct CivitaiServiceUserTests {
    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubUserByIdURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func fetchUserDecodesProfile() async throws {
        StubUserByIdURLProtocol.handler = { _ in
            (200, Data(#"[{"result":{"data":{"json":{"id":42,"username":"alice","image":"https://cdn/x.jpg","deletedAt":null}}}}]"#.utf8))
        }
        defer { StubUserByIdURLProtocol.handler = nil }

        let user = try await makeService().fetchUser(id: 42)
        #expect(user?.id == 42)
        #expect(user?.username == "alice")
        #expect(user?.image == "https://cdn/x.jpg")
    }

    @Test func fetchUserReturnsNilForDeleted() async throws {
        StubUserByIdURLProtocol.handler = { _ in
            (200, Data(#"[{"result":{"data":{"json":{"id":7,"username":"ghost","image":null,"deletedAt":"2025-01-01T00:00:00Z"}}}}]"#.utf8))
        }
        defer { StubUserByIdURLProtocol.handler = nil }

        let user = try await makeService().fetchUser(id: 7)
        #expect(user == nil)
    }

    @Test func fetchUserReturnsNilForEmptyArray() async throws {
        StubUserByIdURLProtocol.handler = { _ in (200, Data("[]".utf8)) }
        defer { StubUserByIdURLProtocol.handler = nil }
        let user = try await makeService().fetchUser(id: 99)
        #expect(user == nil)
    }

    @Test func fetchUserThrowsOnServerError() async {
        StubUserByIdURLProtocol.handler = { _ in (500, Data("boom".utf8)) }
        defer { StubUserByIdURLProtocol.handler = nil }

        await #expect(throws: HTTPStatusError.self) {
            _ = try await self.makeService().fetchUser(id: 1)
        }
    }
}
