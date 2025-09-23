import Foundation

struct CivitaiImage: Codable, Identifiable {
    let id: Int
    let name: String?
    private let url: String // Make this private since we need to construct the full URL
    let width: Int?
    let height: Int?
    let nsfwLevel: Int
    let type: String
    let postId: Int
    let hash: String?
    let user: CivitaiUser?  // Made optional since it's not always present in posts
    let stats: ImageStats?  // Made optional since it's not always present in posts
    let hasMeta: Bool
    let meta: ImageMeta?

    var detailURL: String {
        if isVideo {
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/anim=true,transcode=true,width=400/\(id).mp4"
        } else {
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/anim=false,width=400/\(id).jpeg"
        }
    }
    
    var isVideo: Bool {
        return type == "video"
    }
    
    var nsfw: Bool {
        return nsfwLevel > 2
    }
}

struct ImageStats: Codable {
    let likeCountAllTime: Int
    let laughCountAllTime: Int
    let heartCountAllTime: Int
    let cryCountAllTime: Int
    let commentCountAllTime: Int
    let collectedCountAllTime: Int
    let tippedAmountCountAllTime: Int
    let dislikeCountAllTime: Int
    let viewCountAllTime: Int
}

struct ImageMeta: Codable {
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
