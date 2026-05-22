import Testing
import Foundation
@testable import Diffusely

struct CreateCollectionTests {

    /// Pulls the inner `{ name, type, description?, read }` json object out of
    /// the tRPC batch envelope produced by makeUpsertBody.
    private func innerJSON(_ body: [String: Any]) throws -> [String: Any] {
        let zero = try #require(body["0"] as? [String: Any])
        return try #require(zero["json"] as? [String: Any])
    }

    @Test func imageCollectionPayload() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "My Pics", type: "Image", description: "best of", read: "Private"
        )
        let json = try innerJSON(body)
        #expect(json["name"] as? String == "My Pics")
        #expect(json["type"] as? String == "Image")
        #expect(json["description"] as? String == "best of")
        #expect(json["read"] as? String == "Private")
    }

    @Test func postCollectionPublicPayload() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "My Posts", type: "Post", description: nil, read: "Public"
        )
        let json = try innerJSON(body)
        #expect(json["name"] as? String == "My Posts")
        #expect(json["type"] as? String == "Post")
        #expect(json["read"] as? String == "Public")
        // description omitted when nil
        #expect(json["description"] == nil)
    }

    @Test func emptyDescriptionOmitted() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "X", type: "Image", description: "   ", read: "Unlisted")
        let json = try innerJSON(body)
        #expect(json["description"] == nil)
        #expect(json["read"] as? String == "Unlisted")
    }

    /// The body must serialize cleanly to JSON (it is passed to JSONSerialization).
    @Test func payloadIsSerializable() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "X", type: "Post", description: "y", read: "Private")
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(!data.isEmpty)
    }
}
