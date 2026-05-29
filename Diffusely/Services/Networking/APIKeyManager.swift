import Foundation

@MainActor
class APIKeyManager: ObservableObject {
    static let shared = APIKeyManager()

    @Published var apiKey: String? {
        didSet {
            if let key = apiKey {
                UserDefaults.standard.set(key, forKey: "civitai_api_key")
            } else {
                UserDefaults.standard.removeObject(forKey: "civitai_api_key")
            }
        }
    }

    var hasAPIKey: Bool {
        apiKey != nil && !apiKey!.isEmpty
    }

    private init() {
        self.apiKey = UserDefaults.standard.string(forKey: "civitai_api_key")
    }

    func clearAPIKey() {
        apiKey = nil
    }
}
