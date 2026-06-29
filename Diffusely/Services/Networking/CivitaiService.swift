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

/// Thrown when an HTTP response carries a non-2xx status code. Surfacing the
/// status this way (rather than letting the error body fail JSON decoding as a
/// `DecodingError`) lets the sync retry classifier back off on 429/5xx instead
/// of treating a rate-limit or transient server error as fatal.
struct HTTPStatusError: Error, Equatable {
    let statusCode: Int
}

@MainActor
class CivitaiService: ObservableObject {
    @Published var images: [CivitaiImage] = []
    @Published var posts: [CivitaiPost] = []
    @Published var collections: [CivitaiCollection] = []
    @Published var isLoading = false
    @Published var error: Error?

    // Bit flags PG|PG13|R|X|XXX. Server caps per-domain (civitai.com → PG+PG13,
    // civitai.red → uncapped), so always requesting all levels yields the right
    // content for whichever source the user picked.
    private let browsingLevel = 31

    private var baseURL: String { DomainManager.shared.baseURL }
    // Account-level operations (follow graph, etc.) belong to the user's
    // civitai.com account and must not follow the content-browsing domain.
    private var accountBaseURL: String { CivitaiDomain.safe.baseURL }
    private var nextCursor: String?
    private var nextPostCursor: Int?
    private let session: URLSession
    private var currentTask: Task<Void, Never>?
    private let mediaCacheService = MediaCacheService.shared

    init(session: URLSession = .civitai) {
        self.session = session
    }

    /// Throws `HTTPStatusError` when `response` is a non-2xx HTTP response so
    /// callers fail fast with the status code instead of decoding an error body.
    private func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode)
        }
    }

    /// Fetches `request` with a hard wall-clock deadline. The session's
    /// `timeoutIntervalForRequest` does NOT fire while a request is waiting for a
    /// connection/stream (e.g. a stalled HTTP/3/QUIC handshake), so a wedged
    /// request can hang far longer than expected — leaving the feed blank with no
    /// visible error. Racing the fetch against an explicit `Task.sleep` and
    /// cancelling the loser guarantees a stuck request throws `URLError(.timedOut)`
    /// instead of hanging indefinitely, routing into each caller's existing
    /// `catch` (the feed surfaces it via `error`). Mirrors the pattern in
    /// `MediaCacheService.fetchImageWithTimeout` for image bytes.
    ///
    /// `Foundation.Data` is spelled out because this file declares a generic
    /// `Data` tRPC envelope type that would otherwise shadow it.
    private func fetchWithTimeout(_ request: URLRequest, timeout: TimeInterval = 20) async throws -> (Foundation.Data, URLResponse) {
        let session = self.session
        return try await withThrowingTaskGroup(of: (Foundation.Data, URLResponse).self) { group in
            group.addTask {
                try await session.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            // First child to finish wins; the other is cancelled by the defer.
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            return result
        }
    }

    func clear() {
        currentTask?.cancel()
        images.removeAll()
        posts.removeAll()
        nextCursor = nil
        nextPostCursor = nil
    }
    
    func fetchImages(videos: Bool, limit: Int = 20, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil) async {
        // Cancel any in-flight request and wait for it to fully unwind before
        // starting a new one. Cancellation is cooperative, so `isLoading` and the
        // task aren't settled the instant we call cancel(); awaiting the old task
        // here avoids the race where a refresh (clear + immediate refetch) got
        // dropped by a still-true `isLoading` guard and left the feed blank.
        let inFlight = currentTask
        inFlight?.cancel()
        await inFlight?.value

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

                let (data, _) = try await fetchWithTimeout(request)

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
    
    func loadMoreImages(videos: Bool, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil, username: String? = nil) async {
        // Skip if there's no next page or a load is already running. The latter
        // dedups the burst of prefetch triggers the feed fires as the user nears
        // the end, so we don't cancel-and-restart an in-flight page repeatedly.
        guard nextCursor != nil, !isLoading else { return }
        await fetchImages(videos: videos, period: period, sort: sort, collectionId: collectionId, username: username)
    }

    func fetchPosts(limit: Int = 20, period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil) async {
        // Cancel any in-flight request and wait for it to fully unwind before
        // starting a new one — see fetchImages for why awaiting (rather than a
        // stale `isLoading` guard) is what keeps a refresh from blanking the feed.
        let inFlight = currentTask
        inFlight?.cancel()
        await inFlight?.value

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

                let (data, _) = try await fetchWithTimeout(request)

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

    func loadMorePosts(period: Timeframe = .week, sort: FeedSort = .mostCollected, collectionId: Int? = nil) async {
        guard nextPostCursor != nil, !isLoading else { return }
        await fetchPosts(period: period, sort: sort, collectionId: collectionId)
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

        var request = URLRequest(url: url)
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await session.data(for: request)

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

    /// Fetches a single image by id via `/api/trpc/image.get`. Used by
    /// `LibraryDateBackfillService` to retrieve `publishedAt` for library items
    /// saved before sidecar schema v3.
    func fetchImage(imageId: Int) async throws -> CivitaiImage {
        var components = URLComponents(string: "\(baseURL)/image.get")!

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

        var request = URLRequest(url: url)
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await session.data(for: request)

        // image.get returns a single image object (not an array), mirroring
        // image.getGenerationData's response shape.
        struct SingleResponse: Codable {
            let result: SingleResult
        }
        struct SingleResult: Codable {
            let data: SingleData
        }
        struct SingleData: Codable {
            let json: CivitaiImage
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

        var request = URLRequest(url: url)
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await session.data(for: request)

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
            "browsingLevel": browsingLevel,
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

        var imageRequest = URLRequest(url: imageUrl)
        if let apiKey = APIKeyManager.shared.apiKey {
            imageRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (imageData, _) = try await session.data(for: imageRequest)

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

        // The basic list lacks the `type` field, so enrich each collection with
        // a `collection.getById` call. These run with bounded concurrency (the
        // old code did them serially, which made a slow API unbearable). A
        // detail fetch that fails degrades gracefully to the basic collection
        // rather than dropping it — the row is still cached and the next list
        // sync retries it. Resilience/backoff for the whole operation lives in
        // CollectionListSyncService (mirroring the contents-sync pattern), so
        // this method intentionally does not retry.
        let maxConcurrent = 6
        var detailed = [CivitaiCollection?](repeating: nil, count: basicCollections.count)

        try await withThrowingTaskGroup(of: (Int, CivitaiCollection).self) { group in
            var nextIndex = 0

            func addTask(_ index: Int) {
                let basic = basicCollections[index]
                group.addTask {
                    let resolved = (try? await self.getCollectionById(id: basic.id)) ?? basic
                    return (index, resolved)
                }
            }

            while nextIndex < min(maxConcurrent, basicCollections.count) {
                addTask(nextIndex)
                nextIndex += 1
            }

            while let (index, collection) = try await group.next() {
                detailed[index] = collection
                if nextIndex < basicCollections.count {
                    try Task.checkCancellation()
                    addTask(nextIndex)
                    nextIndex += 1
                }
            }
        }

        // Reassemble in the server's original order.
        return detailed.compactMap { $0 }
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

    /// Builds the tRPC request body for `collection.upsert`. Pure/testable.
    /// A trimmed-empty or nil `description` is omitted from the payload.
    nonisolated static func makeUpsertBody(
        name: String,
        type: String,
        description: String?,
        read: String
    ) -> [String: Any] {
        var json: [String: Any] = [
            "name": name,
            "type": type,
            "read": read
        ]
        if let description = description,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            json["description"] = description
        }
        return ["0": ["json": json]]
    }

    /// Creates a new collection via `collection.upsert`. Returns the new
    /// collection's id. Requires an API key.
    /// - Parameters:
    ///   - type: "Image" or "Post".
    ///   - read: "Private", "Public", or "Unlisted".
    func createCollection(
        name: String,
        type: String,
        description: String?,
        read: String
    ) async throws -> Int {
        let url = URL(string: "\(baseURL)/collection.upsert?batch=1")!

        let bodyData = try JSONSerialization.data(
            withJSONObject: CivitaiService.makeUpsertBody(
                name: name, type: type, description: description, read: read))

        print("Creating collection: \(name)")
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

        struct UpsertResponse: Decodable {
            let result: UpsertResult
        }
        struct UpsertResult: Decodable {
            let data: UpsertData
        }
        struct UpsertData: Decodable {
            let json: UpsertCollection
        }
        struct UpsertCollection: Decodable {
            let id: Int
        }

        let decoded = try JSONDecoder().decode([UpsertResponse].self, from: data)
        guard let id = decoded.first?.result.data.json.id else {
            throw URLError(.cannotParseResponse)
        }
        return id
    }

    /// Adds the target item to `adding` collections and removes it from
    /// `removing` collections in a single `collection.saveItem` request.
    /// Either array may be empty; both arrays empty is a no-op but still sends
    /// the request (caller should avoid this).
    func saveItem(
        target: ManageCollectionsTarget,
        adding: [Int],
        removing: [Int]
    ) async throws {
        let url = URL(string: "\(baseURL)/collection.saveItem?batch=1")!

        var inputParams: [String: Any] = [
            "type": target.collectionType,
            "collections": adding.map { ["collectionId": $0] },
            "removeFromCollectionIds": removing
        ]
        switch target {
        case .image(let image): inputParams["imageId"] = image.id
        case .post(let post):   inputParams["postId"] = post.id
        }

        let tRPCInput = ["0": ["json": inputParams]]
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
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// Returns the collection ids that contain the given image or post,
    /// filtered to collections the authenticated user can write to.
    /// Source of truth for the "Manage Collections" sheet's membership state.
    func getUserCollectionItemsByItem(target: ManageCollectionsTarget) async throws -> [Int] {
        var components = URLComponents(string: "\(baseURL)/collection.getUserCollectionItemsByItem")!

        var inputParams: [String: Any] = [
            "type": target.collectionType,
            "contributingOnly": true
        ]
        switch target {
        case .image(let image): inputParams["imageId"] = image.id
        case .post(let post):   inputParams["postId"] = post.id
        }

        let tRPCInput = ["0": ["json": inputParams]]
        let inputData = try JSONSerialization.data(withJSONObject: tRPCInput)
        let inputString = String(data: inputData, encoding: .utf8)!

        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString)
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        guard let apiKey = APIKeyManager.shared.apiKey else {
            throw URLError(.userAuthenticationRequired)
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        struct Envelope: Decodable {
            let result: ResultBox
            struct ResultBox: Decodable { let data: DataBox }
            struct DataBox: Decodable { let json: [Item] }
            struct Item: Decodable { let collectionId: Int }
        }
        let decoded = try JSONDecoder().decode([Envelope].self, from: data)
        return decoded[0].result.data.json.map(\.collectionId)
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

    /// Fetches the IDs of the users the authenticated user is following
    func getFollowingUserIds() async throws -> [Int] {
        var components = URLComponents(string: "\(accountBaseURL)/user.getFollowingUsers")!

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
            let json: [Int]
        }

        let tRPCResponse = try JSONDecoder().decode([FollowingResponse].self, from: data)
        return tRPCResponse[0].result.data.json
    }

    /// Toggles follow state for a user. Throws on failure.
    func toggleFollowUser(targetUserId: Int) async throws {
        let url = URL(string: "\(accountBaseURL)/user.toggleFollow?batch=1")!

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

    // MARK: - User Lookup

    /// Resolves a single user id to a display profile via `user.getById`.
    /// Returns nil when the user is deleted or the response carries no user
    /// (e.g. a tRPC not-found), so callers can hide them. Throws on transport
    /// errors or non-2xx HTTP status so callers can retry.
    func fetchUser(id: Int) async throws -> CivitaiUser? {
        var components = URLComponents(string: "\(accountBaseURL)/user.getById")!

        let tRPCInput = [
            "0": ["json": ["id": id]]
        ]
        let inputData = try JSONSerialization.data(withJSONObject: tRPCInput)
        let inputString = String(data: inputData, encoding: .utf8)!

        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString)
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        // `user.getById` is a public endpoint, so the API key is optional here
        // (unlike `getFollowingUserIds`, which requires an authenticated account).
        if let apiKey = APIKeyManager.shared.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await fetchWithTimeout(request)
        try validateStatus(response)

        struct UserByIdResponse: Codable { let result: UserByIdResult }
        struct UserByIdResult: Codable { let data: UserByIdData }
        struct UserByIdData: Codable { let json: UserJSON }
        struct UserJSON: Codable {
            let id: Int
            let username: String?
            let image: String?
            let deletedAt: String?
        }

        let decoded = try JSONDecoder().decode([UserByIdResponse].self, from: data)
        guard let json = decoded.first?.result.data.json else { return nil }
        if json.deletedAt != nil { return nil }
        return CivitaiUser(id: json.id, username: json.username, image: json.image)
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

        let (data, httpResponse) = try await fetchWithTimeout(request)
        try validateStatus(httpResponse)
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

        let (data, httpResponse) = try await fetchWithTimeout(request)
        try validateStatus(httpResponse)
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
