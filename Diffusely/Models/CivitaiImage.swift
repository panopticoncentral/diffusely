import Foundation

struct CivitaiImage: Codable, Identifiable, Hashable {
    let id: Int
    private let url: String // Make this private since we need to construct the full URL
    let width: Int
    let height: Int
    let nsfwLevel: Int
    let type: String
    let postId: Int?  // The post that the image belongs to
    let user: CivitaiUser?  // Made optional since it's not always present in posts
    let stats: ImageStats?  // Made optional since it's not always present in posts

    var detailURL: String {
        if isVideo {
            // Use standard width transcode that's likely cached on CDN
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/transcode=true,width=450,optimized=true/\(id).mp4"
        } else {
            // Use standard format that's likely cached on CDN
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/anim=false,width=450,optimized=true/\(id).jpeg"
        }
    }
    
    var isVideo: Bool {
        return type == "video"
    }
}

struct ImageStats: Codable, Hashable {
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
