import Foundation

enum CivitaiDomain: String, CaseIterable, Identifiable {
    case safe = "civitai.com"
    case mature = "civitai.red"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safe: return "Civitai (up to PG-13)"
        case .mature: return "Civitai Red (mature)"
        }
    }

    var baseURL: String {
        "https://\(rawValue)/api/trpc"
    }
}

@MainActor
class DomainManager: ObservableObject {
    static let shared = DomainManager()

    private static let storageKey = "civitai_domain"

    @Published var domain: CivitaiDomain {
        didSet {
            UserDefaults.standard.set(domain.rawValue, forKey: Self.storageKey)
        }
    }

    var baseURL: String { domain.baseURL }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = CivitaiDomain(rawValue: raw) {
            self.domain = stored
        } else {
            self.domain = .safe
        }
    }
}
