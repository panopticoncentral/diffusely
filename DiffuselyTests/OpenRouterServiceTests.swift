import Testing
import Foundation
@testable import Diffusely

@Suite struct OpenRouterServiceTests {
    @Test func requestCarriesModelMessagesAndJSONMode() throws {
        let request = try OpenRouterClassifier.makeRequest(
            apiKey: "sk-test", model: "deepseek/deepseek-v4",
            system: "sys", user: "usr")
        #expect(request.url == OpenRouterClassifier.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "deepseek/deepseek-v4")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[0]["content"] == "sys")
        #expect(messages?[1]["role"] == "user")
        #expect(messages?[1]["content"] == "usr")
        let format = body?["response_format"] as? [String: String]
        #expect(format?["type"] == "json_object")
    }

    @Test func extractsAssistantContent() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"{\\"ok\\":true}"}}]}
        """.utf8)
        #expect(try OpenRouterClassifier.extractContent(from: data) == "{\"ok\":true}")
    }

    @Test func malformedResponseThrows() {
        #expect(throws: OpenRouterError.malformedResponse) {
            try OpenRouterClassifier.extractContent(from: Data("{}".utf8))
        }
        #expect(throws: OpenRouterError.malformedResponse) {
            try OpenRouterClassifier.extractContent(from: Data("not json".utf8))
        }
    }
}
