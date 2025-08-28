//
//  CivitaiImage.swift
//  Diffusely
//
//  Created by Claude on 8/20/25.
//

import Foundation

struct TRPCBatchResponse: Codable {
    let result: TRPCResult
}

struct TRPCResult: Codable {
    let data: TRPCData
}

struct TRPCData: Codable {
    let json: CivitaiImageResponse
}

struct CivitaiImageResponse: Codable {
    let items: [CivitaiImage]
    let nextCursor: AnyCursor?
}

// Support both Int and String cursor types
enum AnyCursor: Codable {
    case int(Int)
    case string(String)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(AnyCursor.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Int or String"))
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

struct CivitaiImage: Codable, Identifiable {
    let id: Int
    let name: String?
    private let url: String // Make this private since we need to construct the full URL
    let nsfwLevel: Int
    let width: Int?
    let height: Int?
    let hash: String?
    let hasMeta: Bool
    let hasPositivePrompt: Bool?
    let onSite: Bool
    let remixOfId: Int?
    let createdAt: String
    let sortAt: String
    let mimeType: String?
    let type: String
    let metadata: ImageMetadata?
    let index: Int?
    let minor: Bool?
    let acceptableMinor: Bool?
    let postId: Int
    let postTitle: String?
    let publishedAt: String?
    let modelVersionId: Int?
    let availability: String
    let meta: ImageGenerationProps?
    let baseModel: String?
    let tagIds: [Int]?
    let user: CivitaiUser
    let stats: IndexedImageStats
    let thumbnailUrl: String?
    
    // Additional fields for indexed response
    let reactionCount: Int?
    let commentCount: Int?
    let collectedCount: Int?
    
    // Computed property to return the full image URL
    var fullURL: String {
        if url.hasPrefix("http") {
            return url
        } else {
            // Construct full URL from the image ID/hash
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/original=true/\(url).jpeg"
        }
    }
    
    var isVideo: Bool {
        return type == "video"
    }
    
    var nsfw: Bool {
        return nsfwLevel > 2
    }
    
    // For compatibility with views expecting username directly
    var username: String? {
        return user.username
    }
}

struct CivitaiUser: Codable {
    let id: Int
    let username: String?
    let image: String?
    let deletedAt: String?
}

// Stats structure for indexed responses (useIndex: true)
struct IndexedImageStats: Codable {
    let likeCountAllTime: Int
    let laughCountAllTime: Int
    let heartCountAllTime: Int
    let cryCountAllTime: Int
    let commentCountAllTime: Int
    let collectedCountAllTime: Int
    let tippedAmountCountAllTime: Int
    let dislikeCountAllTime: Int
    let viewCountAllTime: Int
    
    // For compatibility with existing views
    var likeCount: Int? { likeCountAllTime }
    var commentCount: Int? { commentCountAllTime }
    var heartCount: Int? { heartCountAllTime }
}

// Legacy stats structure for non-indexed responses
struct ImageStats: Codable {
    let likeCountAllTime: Int
    let laughCountAllTime: Int
    let heartCountAllTime: Int
    let cryCountAllTime: Int
    let commentCountAllTime: Int
    let collectedCountAllTime: Int
    let tippedAmountCountAllTime: Int
    
    // For compatibility with existing views
    var likeCount: Int? { likeCountAllTime }
    var commentCount: Int? { commentCountAllTime }
    var heartCount: Int? { heartCountAllTime }
}

struct ImageMetadata: Codable {
    let hash: String?
    let size: Int?
    let width: Int
    let height: Int
}

struct ImageGenerationProps: Codable {
    let prompt: String?
    let negativePrompt: String?
    let cfgScale: Double?
    let steps: Int?
    let sampler: String?
    let seed: Int?
    let clipSkip: Int?
    let model: String?
    let modelHash: String?
    let baseModel: String?
    let size: String?
    
    enum CodingKeys: String, CodingKey {
        case prompt
        case negativePrompt
        case cfgScale
        case steps
        case sampler
        case seed
        case clipSkip = "Clip skip"
        case model = "Model"
        case modelHash = "Model hash"
        case baseModel
        case size = "Size"
    }
}

// For compatibility with existing views that expect ImageMeta
typealias ImageMeta = ImageGenerationProps
