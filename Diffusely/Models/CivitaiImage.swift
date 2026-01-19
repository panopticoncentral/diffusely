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
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/original=true/\(id).mp4"
        } else {
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/width=1024/\(id).jpeg"
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
