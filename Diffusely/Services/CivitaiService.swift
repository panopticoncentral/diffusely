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
    @Published var collections: [CivitaiCollection] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let baseURL = "https://civitai.com/api/trpc"
    private var nextCursor: String?
    private var nextPostCursor: Int?
    private let session = URLSession.shared
    private var currentTask: Task<Void, Never>?
    private let mediaCacheService = MediaCacheService.shared

    func clear() {
        currentTask?.cancel()
        images.removeAll()
        posts.removeAll()
        nextCursor = nil
        nextPostCursor = nil
    }
    
    func fetchImages(videos: Bool, limit: Int = 20, browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil) async {
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
                ]

                if let collectionId = collectionId {
                    inputParams["collectionId"] = collectionId
                } else {
                    inputParams["useIndex"] = true
                    if let username = username {
                        inputParams["username"] = username
                    }
                }

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

                var request = URLRequest(url: url)

                // Add API key if available
                if let apiKey = APIKeyManager.shared.apiKey {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }

                let (data, _) = try await session.data(for: request)

                // Check if task was cancelled
                try Task.checkCancellation()

                let tRPCResponse = try JSONDecoder().decode([Response<CivitaiImage>].self, from: data)
                let response = tRPCResponse[0].result.data.json

                let newImages = response.items
                images.append(contentsOf: newImages)

                // Trigger preloading for newly added images
                if !newImages.isEmpty {
                    mediaCacheService.preloadImages(newImages)
                }

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
    
    func loadMoreImages(videos: Bool, browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil) async {
        guard nextCursor != nil else { return }
        await fetchImages(videos: videos, browsingLevel: browsingLevel, period: period, sort: sort, collectionId: collectionId, username: username)
    }

    func fetchPosts(limit: Int = 20, browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil) async {
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
                    "limit": limit
                ]

                if let collectionId = collectionId {
                    inputParams["collectionId"] = collectionId
                }

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

                var request = URLRequest(url: url)

                // Add API key if available
                if let apiKey = APIKeyManager.shared.apiKey {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }

                let (data, _) = try await session.data(for: request)

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

    func loadMorePosts(browsingLevel: Int = 3, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil) async {
        guard nextPostCursor != nil else { return }
        await fetchPosts(browsingLevel: browsingLevel, period: period, sort: sort, collectionId: collectionId)
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

    func getAllUserCollections() async throws -> [CivitaiCollection] {
        var components = URLComponents(string: "\(baseURL)/collection.getAllUser")!

        let tRPCInput = [
            "0": [
                "json": [String: Any]()
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

        var request = URLRequest(url: url)

        // Add API key if available
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await session.data(for: request)

        struct CollectionResponse: Codable {
            let result: CollectionResult
        }

        struct CollectionResult: Codable {
            let data: CollectionData
        }

        struct CollectionData: Codable {
            let json: [CivitaiCollection]
        }

        let tRPCResponse = try JSONDecoder().decode([CollectionResponse].self, from: data)
        let basicCollections = tRPCResponse[0].result.data.json

        // Fetch full details for each collection to get the type field
        var detailedCollections: [CivitaiCollection] = []
        for collection in basicCollections {
            do {
                let detailedCollection = try await getCollectionById(id: collection.id)
                detailedCollections.append(detailedCollection)
            } catch {
                // If we fail to get details for one collection, skip it
                print("Failed to fetch details for collection \(collection.id): \(error)")
            }
        }

        return detailedCollections
    }

    func getCollectionById(id: Int) async throws -> CivitaiCollection {
        var components = URLComponents(string: "\(baseURL)/collection.getById")!

        let inputParams: [String: Any] = [
            "id": id
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

        var request = URLRequest(url: url)

        // Add API key if available
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await session.data(for: request)

        struct CollectionDetailResponse: Codable {
            let result: CollectionDetailResult
        }

        struct CollectionDetailResult: Codable {
            let data: CollectionDetailData
        }

        struct CollectionDetailData: Codable {
            let json: CollectionWrapper
        }

        struct CollectionWrapper: Codable {
            let collection: CivitaiCollection
        }

        let tRPCResponse = try JSONDecoder().decode([CollectionDetailResponse].self, from: data)
        return tRPCResponse[0].result.data.json.collection
    }

    func addImageToCollection(imageId: Int, collectionId: Int) async throws {
        let url = URL(string: "\(baseURL)/collection.saveItem?batch=1")!

        let inputParams: [String: Any] = [
            "imageId": imageId,
            "type": "Image",
            "collections": [
                ["collectionId": collectionId]
            ]
        ]

        let tRPCInput = [
            "0": [
                "json": inputParams
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: tRPCInput)

        print("Adding image \(imageId) to collection \(collectionId)")
        print("Request URL: \(url)")
        if let bodyString = String(data: bodyData, encoding: .utf8) {
            print("Request body: \(bodyString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // API key is required for this endpoint
        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        if let responseString = String(data: data, encoding: .utf8) {
            print("Response body: \(responseString)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("Response status code: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func getUserImageCollections() async throws -> [CivitaiCollection] {
        var components = URLComponents(string: "\(baseURL)/collection.getAllUser")!

        let inputParams: [String: Any] = [
            "type": "Image"
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

        var request = URLRequest(url: url)

        // API key is required for this endpoint
        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        struct CollectionResponse: Codable {
            let result: CollectionResult
        }

        struct CollectionResult: Codable {
            let data: CollectionData
        }

        struct CollectionData: Codable {
            let json: [CivitaiCollection]
        }

        let tRPCResponse = try JSONDecoder().decode([CollectionResponse].self, from: data)
        return tRPCResponse[0].result.data.json
    }

    func addPostToCollection(postId: Int, collectionId: Int) async throws {
        let url = URL(string: "\(baseURL)/collection.saveItem?batch=1")!

        let inputParams: [String: Any] = [
            "postId": postId,
            "type": "Post",
            "collections": [
                ["collectionId": collectionId]
            ]
        ]

        let tRPCInput = [
            "0": [
                "json": inputParams
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: tRPCInput)

        print("Adding post \(postId) to collection \(collectionId)")
        print("Request URL: \(url)")
        if let bodyString = String(data: bodyData, encoding: .utf8) {
            print("Request body: \(bodyString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        if let responseString = String(data: data, encoding: .utf8) {
            print("Response body: \(responseString)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("Response status code: \(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func getUserPostCollections() async throws -> [CivitaiCollection] {
        var components = URLComponents(string: "\(baseURL)/collection.getAllUser")!

        let inputParams: [String: Any] = [
            "type": "Post"
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

        var request = URLRequest(url: url)

        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        struct CollectionResponse: Codable {
            let result: CollectionResult
        }

        struct CollectionResult: Codable {
            let data: CollectionData
        }

        struct CollectionData: Codable {
            let json: [CivitaiCollection]
        }

        let tRPCResponse = try JSONDecoder().decode([CollectionResponse].self, from: data)
        return tRPCResponse[0].result.data.json
    }

    // MARK: - Follow/Unfollow

    /// Fetches the list of users the authenticated user is following
    func getFollowingUsers() async throws -> [CivitaiUser] {
        var components = URLComponents(string: "\(baseURL)/user.getFollowingUsers")!

        let tRPCInput = [
            "0": [
                "json": [String: Any]()
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

        var request = URLRequest(url: url)

        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        struct FollowingResponse: Codable {
            let result: FollowingResult
        }

        struct FollowingResult: Codable {
            let data: FollowingData
        }

        struct FollowingData: Codable {
            let json: [CivitaiUser]
        }

        let tRPCResponse = try JSONDecoder().decode([FollowingResponse].self, from: data)
        return tRPCResponse[0].result.data.json
    }

    /// Toggles follow state for a user. Throws on failure.
    func toggleFollowUser(targetUserId: Int) async throws {
        let url = URL(string: "\(baseURL)/user.toggleFollow?batch=1")!

        let inputParams: [String: Any] = [
            "targetUserId": targetUserId
        ]

        let tRPCInput = [
            "0": [
                "json": inputParams
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: tRPCInput)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Paginated Fetch Methods for Sync Service

    /// Fetches a page of images for a collection, returning the raw results
    func fetchImagesPage(collectionId: Int, cursor: String? = nil, limit: Int = 100) async throws -> (images: [CivitaiImage], nextCursor: String?) {
        var components = URLComponents(string: "\(baseURL)/image.getInfinite")!

        var inputParams: [String: Any] = [
            "limit": limit,
            "collectionId": collectionId,
            "sort": "Newest"
        ]

        if let cursor = cursor {
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

        var request = URLRequest(url: url)
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await session.data(for: request)
        let tRPCResponse = try JSONDecoder().decode([Response<CivitaiImage>].self, from: data)
        let response = tRPCResponse[0].result.data.json

        return (images: response.items, nextCursor: response.nextCursor?.stringValue)
    }

    /// Fetches a page of posts for a collection, returning the raw results
    /// Note: Post cursors can be Int or String ("value|id" format) - we normalize to String
    func fetchPostsPage(collectionId: Int, cursor: String? = nil, limit: Int = 100) async throws -> (posts: [CivitaiPost], nextCursor: String?) {
        var components = URLComponents(string: "\(baseURL)/post.getInfinite")!

        var inputParams: [String: Any] = [
            "limit": limit,
            "collectionId": collectionId,
            "sort": "Newest"
        ]

        if let cursor = cursor {
            // Try to parse as Int first (API may expect Int), otherwise use as String
            if let intCursor = Int(cursor) {
                inputParams["cursor"] = intCursor
            } else {
                inputParams["cursor"] = cursor
            }
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

        var request = URLRequest(url: url)
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await session.data(for: request)
        let tRPCResponse = try JSONDecoder().decode([Response<CivitaiPost>].self, from: data)
        let response = tRPCResponse[0].result.data.json

        // Handle both Int and String cursor formats by using stringValue
        return (posts: response.items, nextCursor: response.nextCursor?.stringValue)
    }

    /// Fetches a single preview image for a collection
    func fetchCollectionPreviewImage(collectionId: Int, collectionType: String) async throws -> CivitaiImage? {
        if collectionType == "Image" {
            // Fetch directly from images
            var components = URLComponents(string: "\(baseURL)/image.getInfinite")!

            let inputParams: [String: Any] = [
                "limit": 1,
                "collectionId": collectionId,
                "sort": "Newest"
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

            var request = URLRequest(url: url)
            if let apiKey = APIKeyManager.shared.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, _) = try await session.data(for: request)
            let tRPCResponse = try JSONDecoder().decode([Response<CivitaiImage>].self, from: data)
            return tRPCResponse[0].result.data.json.items.first
        } else if collectionType == "Post" {
            // Fetch from posts and get first image
            var components = URLComponents(string: "\(baseURL)/post.getInfinite")!

            let inputParams: [String: Any] = [
                "limit": 1,
                "collectionId": collectionId,
                "sort": "Newest"
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

            var request = URLRequest(url: url)
            if let apiKey = APIKeyManager.shared.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, _) = try await session.data(for: request)
            let tRPCResponse = try JSONDecoder().decode([Response<CivitaiPost>].self, from: data)
            return tRPCResponse[0].result.data.json.items.first?.images?.first
        }

        return nil
    }
}
