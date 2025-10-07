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
    @Published var posts: [CivitaiPost] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let baseURL = "https://civitai.com/api/trpc"
    private var nextCursor: String?
    private var nextPostCursor: Int?
    private let session = URLSession.shared
    private var currentTask: Task<Void, Never>?

    func clear() {
        currentTask?.cancel()
        images.removeAll()
        posts.removeAll()
        nextCursor = nil
        nextPostCursor = nil
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
                    "limit": limit,
                    "sort": sort.rawValue,
                    "types": [videos ? "video" : "image"],
                    "period": period.rawValue,
                    "browsingLevel": browsingLevel,
                    "useIndex": true,
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

    func fetchPosts(limit: Int = 20, browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected) async {
        // Cancel any existing request
        currentTask?.cancel()

        guard !isLoading else { return }

        currentTask = Task {
            isLoading = true
            error = nil

            do {
                var components = URLComponents(string: "\(baseURL)/post.getInfinite")!

                var inputParams: [String: Any] = [
                    "period": period.rawValue,
                    "sort": sort.rawValue,
                    "browsingLevel": browsingLevel,
                    "limit": limit,
                ]

                if let cursor = nextPostCursor {
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

                let tRPCResponse = try JSONDecoder().decode([Response<CivitaiPost>].self, from: data)
                let response = tRPCResponse[0].result.data.json

                posts.append(contentsOf: response.items)

                if let cursor = response.nextCursor {
                    if case .int(let intValue) = cursor {
                        nextPostCursor = intValue
                    }
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

    func loadMorePosts(browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected) async {
        guard nextPostCursor != nil else { return }
        await fetchPosts(browsingLevel: browsingLevel, period: period, sort: sort)
    }

    func fetchGenerationData(imageId: Int) async throws -> GenerationData {
        var components = URLComponents(string: "\(baseURL)/image.getGenerationData")!

        let inputParams: [String: Any] = [
            "id": imageId
        ]

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

        // The response structure for getGenerationData is different - it returns a single object not an array
        struct SingleResponse: Codable {
            let result: SingleResult
        }

        struct SingleResult: Codable {
            let data: SingleData
        }

        struct SingleData: Codable {
            let json: GenerationData
        }

        let tRPCResponse = try JSONDecoder().decode([SingleResponse].self, from: data)
        return tRPCResponse[0].result.data.json
    }

    func getPost(postId: Int) async throws -> CivitaiPost {
        // First, fetch the basic post information
        var components = URLComponents(string: "\(baseURL)/post.get")!

        let inputParams: [String: Any] = [
            "id": postId
        ]

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

        // post.get returns a single object without images or stats
        struct PostDetail: Codable {
            let id: Int
            let nsfwLevel: Int
            let title: String?
            let user: CivitaiUser
        }

        struct SingleResponse: Codable {
            let result: SingleResult
        }

        struct SingleResult: Codable {
            let data: SingleData
        }

        struct SingleData: Codable {
            let json: PostDetail
        }

        let tRPCResponse = try JSONDecoder().decode([SingleResponse].self, from: data)
        let postDetail = tRPCResponse[0].result.data.json

        // Now fetch the images for this post
        var imageComponents = URLComponents(string: "\(baseURL)/image.getInfinite")!

        let imageInputParams: [String: Any] = [
            "postId": postId,
            "include": []
        ]

        let imageTRPCInput = [
            "0": [
                "json": imageInputParams
            ]
        ]

        let imageInputData = try JSONSerialization.data(withJSONObject: imageTRPCInput)
        let imageInputString = String(data: imageInputData, encoding: .utf8)!

        imageComponents.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: imageInputString)
        ]

        guard let imageUrl = imageComponents.url else {
            throw URLError(.badURL)
        }

        let (imageData, _) = try await session.data(from: imageUrl)

        let imageTRPCResponse = try JSONDecoder().decode([Response<CivitaiImage>].self, from: imageData)
        let imageResponse = imageTRPCResponse[0].result.data.json

        // Combine the post detail and images into a CivitaiPost
        let post = CivitaiPost(
            id: postDetail.id,
            nsfwLevel: postDetail.nsfwLevel,
            title: postDetail.title,
            imageCount: imageResponse.items.count,
            user: postDetail.user,
            stats: PostStats(
                cryCount: 0,
                likeCount: 0,
                heartCount: 0,
                laughCount: 0,
                commentCount: 0,
                dislikeCount: 0
            ),
            images: imageResponse.items
        )

        return post
    }

}
