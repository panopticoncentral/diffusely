import Foundation

struct CivitaiPost: Codable, Identifiable, Hashable {
    let id: Int
    let nsfwLevel: Int
    let title: String?
    let imageCount: Int
    let user: CivitaiUser
    let stats: PostStats
    let images: [CivitaiImage]
}

struct PostStats: Codable, Hashable {
    let cryCount: Int
    let likeCount: Int
    let heartCount: Int
    let laughCount: Int
    let commentCount: Int
    let dislikeCount: Int
}
