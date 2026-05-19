import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// URLProtocol that answers Civitai tRPC collection requests from a closure.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
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

@Suite(.serialized) @MainActor struct CollectionListFetchTests {

    private func makeService() -> CivitaiService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return CivitaiService(session: URLSession(configuration: config))
    }

    private func basicListJSON(ids: [Int]) -> Data {
        let cols = ids.map {
            "{\"id\":\($0),\"name\":\"Col \($0)\",\"description\":null,\"type\":null,\"imageCount\":null,\"image\":null,\"user\":null}"
        }.joined(separator: ",")
        return Data("[{\"result\":{\"data\":{\"json\":[\(cols)]}}}]".utf8)
    }

    private func detailJSON(id: Int, type: String) -> Data {
        Data("""
        [{"result":{"data":{"json":{"collection":{"id":\(id),"name":"Col \(id)","description":"d","type":"\(type)","imageCount":3,"image":null,"user":null}}}}}]
        """.utf8)
    }

    private func idFromGetByIdRequest(_ request: URLRequest) -> Int? {
        guard let url = request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let input = comps.queryItems?.first(where: { $0.name == "input" })?.value,
              let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zero = obj["0"] as? [String: Any],
              let json = zero["json"] as? [String: Any],
              let id = json["id"] as? Int else { return nil }
        return id
    }

    @Test func enrichesTypeAndPreservesServerOrder() async throws {
        let service = makeService()
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("collection.getAllUser") {
                return (200, self.basicListJSON(ids: [3, 1, 2]))
            }
            let id = self.idFromGetByIdRequest(request) ?? -1
            return (200, self.detailJSON(id: id, type: "Image"))
        }

        let result = try await service.getAllUserCollections()

        #expect(result.map(\.id) == [3, 1, 2])           // server order preserved
        #expect(result.allSatisfy { $0.type == "Image" }) // type enriched from detail
        StubURLProtocol.handler = nil
    }

    @Test func failedDetailFallsBackToBasicWithoutDroppingOrThrowing() async throws {
        let service = makeService()
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("collection.getAllUser") {
                return (200, self.basicListJSON(ids: [1, 2]))
            }
            let id = self.idFromGetByIdRequest(request) ?? -1
            if id == 2 { throw URLError(.timedOut) }
            return (200, self.detailJSON(id: id, type: "Image"))
        }

        let result = try await service.getAllUserCollections()

        #expect(result.map(\.id) == [1, 2])     // collection 2 not dropped
        #expect(result.first(where: { $0.id == 1 })?.type == "Image")
        #expect(result.first(where: { $0.id == 2 })?.type == nil) // fell back to basic
        StubURLProtocol.handler = nil
    }

    @Test func basicListFailurePropagatesAsThrownError() async throws {
        let service = makeService()
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }

        await #expect(throws: (any Error).self) {
            _ = try await service.getAllUserCollections()
        }
        StubURLProtocol.handler = nil
    }

    // MARK: - CollectionListSyncService (shares StubURLProtocol — kept in this
    // serialized suite so it never races the fetch tests on the global handler)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PersistedCollection.self, PersistedAuthor.self,
                 PersistedImage.self, PersistedPost.self, PersistedPostImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    /// Awaits a terminal progress state (complete or errored). Polling
    /// `isSyncing` races the not-yet-started task (progress is nil until
    /// performSync runs), so wait for the terminal flags instead.
    private func waitUntilDone(_ service: CollectionListSyncService) async {
        for _ in 0..<250 {
            if let p = service.progress, p.isComplete || p.lastError != nil { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func syncPopulatesCacheAndCompletes() async throws {
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let service = CollectionListSyncService(
            civitaiService: makeService(),
            persistenceService: persistence
        )
        StubURLProtocol.handler = { request in
            if (request.url?.path ?? "").hasSuffix("collection.getAllUser") {
                return (200, self.basicListJSON(ids: [5, 6]))
            }
            let id = self.idFromGetByIdRequest(request) ?? -1
            return (200, self.detailJSON(id: id, type: "Image"))
        }

        service.startSync()
        await waitUntilDone(service)

        #expect(service.progress?.isComplete == true)
        #expect(service.progress?.lastError == nil)
        #expect(persistence.getUserListCollections().map(\.id) == [5, 6])
        #expect(persistence.listNeedsSync(staleAfter: 300) == false)
        StubURLProtocol.handler = nil
    }

    @Test func syncFatalErrorSurfacesAndInterrupts() async throws {
        let persistence = CollectionPersistenceService(modelContext: try makeContext())
        let service = CollectionListSyncService(
            civitaiService: makeService(),
            persistenceService: persistence
        )
        // .badServerResponse classifies as fatal → no retry/backoff.
        StubURLProtocol.handler = { _ in throw URLError(.badServerResponse) }

        service.startSync()
        await waitUntilDone(service)

        #expect(service.progress?.lastError != nil)
        #expect(service.progress?.isComplete != true)
        #expect(service.isSyncing == false)
        StubURLProtocol.handler = nil
    }
}
