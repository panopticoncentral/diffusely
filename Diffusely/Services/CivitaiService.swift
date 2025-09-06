//
//  CivitaiService.swift
//  Diffusely
//
//  Created by Claude on 8/20/25.
//

import Foundation

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
    
    func fetchImages(videos: Bool, limit: Int = 20, browsingLevel: Int = 3, period: Timeframe = .week, sort: ImageSort = .mostCollected) async {
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
                
                let tRPCResponse = try JSONDecoder().decode([TRPCBatchResponse].self, from: data)
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
    
    func loadMore(videos: Bool, browsingLevel: Int = 3, period: Timeframe = .week, sort: ImageSort = .mostCollected) async {
        guard nextCursor != nil else { return }
        await fetchImages(videos: videos, browsingLevel: browsingLevel, period: period, sort: sort)
    }
}
