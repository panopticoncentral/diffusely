import Foundation

fileprivate struct Response<T: Codable>: Codable {
    let result: Result<T>
}

fileprivate struct Result<T: Codable>: Codable {
    let data: Data<T>
}

fileprivate struct Data<T: Codable>: Codable {
    let json: ResponseBody<T>
}

fileprivate struct ResponseBody<T: Codable>: Codable {
    let items: [T]
    let nextCursor: Cursor?
}

fileprivate enum Cursor: Codable {
    case int(Int)
    case string(String)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(Cursor.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Int or String"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let intValue):
            try container.encode(intValue)
        case .string(let stringValue):
            try container.encode(stringValue)
        }
    }
    
    var stringValue: String {
        switch self {
        case .int(let intValue):
            return String(intValue)
        case .string(let stringValue):
            return stringValue
        }
    }
}

@MainActor
class CivitaiService: ObservableObject {
    @Published var images: [CivitaiImage] = []
    @Published var isLoading = false
    @Published var error: Error?
    
    private let baseURL = "https://civitai.com/api/trpc"
    private var nextCursor: String?
    private let session = URLSession.shared
    private var currentTask: Task<Void, Never>?

    func clear() {
        currentTask?.cancel()
        images.removeAll()
        nextCursor = nil
    }
    
    func fetchImages(videos: Bool, limit: Int = 20, browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected) async {
        // Cancel any existing request
        currentTask?.cancel()
        
        guard !isLoading else { return }
        
        currentTask = Task {
            isLoading = true
            error = nil
            
            do {
                var components = URLComponents(string: "\(baseURL)/image.getInfinite")!
                
                var inputParams: [String: Any] = [
                    "period": period.rawValue,
                    "periodMode": "published",
                    "sort": sort.rawValue,
                    "types": [videos ? "video" : "image"],
                    "withMeta": false,
                    "useIndex": true,
                    "browsingLevel": browsingLevel,
                    "limit": limit,
                    "include": ["tags", "meta", "tagIds"]
                ]
                
                if let cursor = nextCursor {
                    inputParams["cursor"] = cursor
                }
                
                let tRPCInput = [
                    "0": [
                        "json": inputParams
                    ]
                ]
                
                let inputData = try JSONSerialization.data(withJSONObject: tRPCInput)
                let inputString = String(data: inputData, encoding: .utf8)!
                
                components.queryItems = [
                    URLQueryItem(name: "batch", value: "1"),
                    URLQueryItem(name: "input", value: inputString)
                ]
                
                guard let url = components.url else {
                    throw URLError(.badURL)
                }
                
                let (data, _) = try await session.data(from: url)
                
                // Check if task was cancelled
                try Task.checkCancellation()
                
                let tRPCResponse = try JSONDecoder().decode([Response<CivitaiImage>].self, from: data)
                let response = tRPCResponse[0].result.data.json
                
                images.append(contentsOf: response.items)
                
                if let cursor = response.nextCursor {
                    nextCursor = cursor.stringValue
                }
            } catch {
                // Don't set error for cancellation - this is expected behavior
                if !(error is CancellationError) && !error.localizedDescription.contains("cancelled") {
                    self.error = error
                }
            }
            
            isLoading = false
        }
        
        await currentTask?.value
    }
    
    func loadMore(videos: Bool, browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected) async {
        guard nextCursor != nil else { return }
        await fetchImages(videos: videos, browsingLevel: browsingLevel, period: period, sort: sort)
    }
}
