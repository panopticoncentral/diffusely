//
//  CivitaiImage.swift
//  Diffusely
//
//  Created by Claude on 8/20/25.
//

import Foundation

struct CivitaiImageResponse: Codable {
    let items: [CivitaiImage]
    let metadata: ResponseMetadata?
}

struct ResponseMetadata: Codable {
    let nextCursor: String?
    let nextPage: String?
}

struct CivitaiImage: Codable, Identifiable {
    let id: Int
    let url: String
    let hash: String?
    let width: Int?
    let height: Int?
    let nsfw: Bool?
    let nsfwLevel: String?
    let type: String?
    let createdAt: String
    let postId: Int?
    let stats: ImageStats?
    let meta: ImageMeta?
    let username: String?
    let baseModel: String?
    
    var isVideo: Bool {
        return type == "video"
    }
}

struct ImageStats: Codable {
    let cryCount: Int?
    let laughCount: Int?
    let likeCount: Int?
    let dislikeCount: Int?
    let heartCount: Int?
    let commentCount: Int?
}

struct ImageMeta: Codable {
    let prompt: String?
    let negativePrompt: String?
    let seed: Int?
    let steps: Int?
    let sampler: String?
    let cfgScale: Double?
    let model: String?
    let modelHash: String?
    let size: String?
    
    enum CodingKeys: String, CodingKey {
        case prompt
        case negativePrompt
        case seed
        case steps
        case sampler
        case cfgScale
        case model
        case modelHash
        case size = "Size"
    }
}