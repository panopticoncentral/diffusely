import Foundation

struct CivitaiPost: Codable, Identifiable {
    let id: Int
    let nsfwLevel: Int
    let title: String?
    let imageCount: Int
    let user: CivitaiUser
    let stats: PostStats
    let images: [CivitaiImage]

    var nsfw: Bool {
        return nsfwLevel > 2
    }
}

struct PostStats: Codable {
    let cryCount: Int
    let likeCount: Int
    let heartCount: Int
    let laughCount: Int
    let commentCount: Int
    let dislikeCount: Int
}