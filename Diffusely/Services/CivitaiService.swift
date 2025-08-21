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
    
    private let baseURL = "https://civitai.com/api/v1"
    private var nextCursor: String?
    private let session = URLSession.shared
    
    func fetchImages(limit: Int = 20, refresh: Bool = false) async {
        if refresh {
            nextCursor = nil
            images.removeAll()
        }
        
        guard !isLoading else { return }
        
        isLoading = true
        error = nil
        
        do {
            var components = URLComponents(string: "\(baseURL)/images")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "sort", value: "Newest")
            ]
            
            if let cursor = nextCursor {
                components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
            }
            
            guard let url = components.url else {
                throw URLError(.badURL)
            }
            
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(CivitaiImageResponse.self, from: data)
            
            if refresh {
                images = response.items
            } else {
                images.append(contentsOf: response.items)
            }
            
            nextCursor = response.metadata?.nextCursor
            
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    func loadMore() async {
        guard nextCursor != nil else { return }
        await fetchImages(refresh: false)
    }
}