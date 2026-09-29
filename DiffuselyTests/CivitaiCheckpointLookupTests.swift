import Testing
import Foundation
@testable import Diffusely

private final class StubCheckpointURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized) @MainActor struct CivitaiCheckpointLookupTests {
    private func service() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubCheckpointURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    @Test func publicImageMetadataReturnsRawCheckpointID() async throws {
        StubCheckpointURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/v1/images")
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.contains(URLQueryItem(name: "imageId", value: "123")))
            #expect(query.contains(URLQueryItem(name: "withMeta", value: "true")))
            return (200, Data(#"{"items":[{"meta":{"prompt":"a portrait","civitaiResources":[{"type":"checkpoint","modelVersionId":290640},{"type":"lora","modelVersionId":215378,"weight":1}]}}]}"#.utf8))
        }
        defer { StubCheckpointURLProtocol.handler = nil }

        #expect(try await service().fetchRawCheckpointVersionID(imageId: 123) == 290640)
    }

    @Test func publicImageMetadataCanCarryRawParametersAsText() async throws {
        StubCheckpointURLProtocol.handler = { _ in
            (200, Data(#"{"items":[{"meta":"Steps: 30, Civitai resources: [{\"type\":\"checkpoint\",\"modelVersionId\":290640}]"}]}"#.utf8))
        }
        defer { StubCheckpointURLProtocol.handler = nil }
        #expect(try await service().fetchRawCheckpointVersionID(imageId: 123) == 290640)
    }

    @Test func versionLookupUsesParentModelNameAndRejectsWrongType() async throws {
        StubCheckpointURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/model-versions/290640")
            return (200, Data(#"{"id":290640,"modelId":257749,"name":"V6","baseModel":"Pony","model":{"name":"Pony Diffusion V6 XL","type":"Checkpoint"}}"#.utf8))
        }
        let checkpoint = try await service().fetchCheckpointVersion(versionId: 290640)
        #expect(checkpoint?.modelName == "Pony Diffusion V6 XL")
        #expect(checkpoint?.versionId == 290640)

        StubCheckpointURLProtocol.handler = { _ in
            (200, Data(#"{"id":290640,"modelId":257749,"name":"V6","model":{"name":"A LoRA","type":"LORA"}}"#.utf8))
        }
        defer { StubCheckpointURLProtocol.handler = nil }
        #expect(try await service().fetchCheckpointVersion(versionId: 290640) == nil)
    }

    @Test func unavailableVersionSurfacesAnHTTP404() async throws {
        StubCheckpointURLProtocol.handler = { _ in (404, Data("missing".utf8)) }
        defer { StubCheckpointURLProtocol.handler = nil }
        do {
            _ = try await service().fetchCheckpointVersion(versionId: 290640)
            Issue.record("Expected the version lookup to fail")
        } catch let error as HTTPStatusError {
            #expect(error.statusCode == 404)
        }
    }
}
