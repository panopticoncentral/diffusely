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

    func clear() {
        images.removeAll()
        nextCursor = nil
    }
    
    func fetchImages(limit: Int = 20) async {
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        
        do {
            var components = URLComponents(string: "\(baseURL)/image.getInfinite")!
            
            var inputParams: [String: Any] = [
                "period": "Week",
                "periodMode": "published",
                "sort": "Most Collected",
                "types": ["image"],
                "withMeta": false,
                "useIndex": true,
                "browsingLevel": 3,
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
            let tRPCResponse = try JSONDecoder().decode([TRPCBatchResponse].self, from: data)
            let response = tRPCResponse[0].result.data.json
            
            images.append(contentsOf: response.items)
            
            if let cursor = response.nextCursor {
                nextCursor = cursor.stringValue
            }
            
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    func loadMore() async {
        guard nextCursor != nil else { return }
        await fetchImages()
    }
}
