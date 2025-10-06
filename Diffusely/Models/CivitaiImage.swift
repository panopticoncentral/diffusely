import Foundation

struct CivitaiImage: Codable, Identifiable {
    let id: Int
    private let url: String // Make this private since we need to construct the full URL
    let width: Int
    let height: Int
    let nsfwLevel: Int
    let type: String
    let user: CivitaiUser?  // Made optional since it's not always present in posts
    let stats: ImageStats?  // Made optional since it's not always present in posts

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
