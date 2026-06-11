import Foundation

/// Settings-backed OpenRouter configuration, mirroring `APIKeyManager`
/// (UserDefaults-backed `@Published` singleton; deliberately untested like its
/// sibling — it is a thin UserDefaults wrapper).
@MainActor
final class OpenRouterConfig: ObservableObject {
    static let shared = OpenRouterConfig()
    static let apiKeyDefaultsKey = "openrouter_api_key"
    static let modelDefaultsKey = "openrouter_model"
    /// OpenRouter model slug. Default chosen for DeepSeek V4; the user can
    /// edit it in Settings if the slug differs.
    static let defaultModel = "deepseek/deepseek-v4"

    @Published var apiKey: String? {
        didSet {
            if let key = apiKey, !key.isEmpty {
                UserDefaults.standard.set(key, forKey: Self.apiKeyDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.apiKeyDefaultsKey)
            }
        }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey) }
    }

    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    private init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey)
        self.model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
    }
}

/// Seam for the Sort Assistant's LLM calls so the pipeline is testable with a
/// stub (mirrors `LibraryDateBackfillService.FetchImageProvider`).
protocol PromptClassifying: Sendable {
    /// One chat completion in JSON mode; returns the assistant message content.
    func completeJSON(system: String, user: String) async throws -> String
}

enum OpenRouterError: Error, Equatable {
    case badStatus(Int)
    case malformedResponse
}

/// Thin OpenRouter chat-completions client.
struct OpenRouterClassifier: PromptClassifying {
    let apiKey: String
    let model: String
    let session: URLSession

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static func makeRequest(apiKey: String, model: String, system: String, user: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.1,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func extractContent(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let content = (try? JSONDecoder().decode(Response.self, from: data))?
            .choices?.first?.message?.content, !content.isEmpty else {
            throw OpenRouterError.malformedResponse
        }
        return content
    }

    func completeJSON(system: String, user: String) async throws -> String {
        let request = try Self.makeRequest(apiKey: apiKey, model: model, system: system, user: user)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenRouterError.badStatus(http.statusCode)
        }
        return try Self.extractContent(from: data)
    }
}
