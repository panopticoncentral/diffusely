import Foundation

struct CivitaiPost: Codable, Identifiable, Hashable {
    let id: Int
    let nsfwLevel: Int
    let title: String?
    let imageCount: Int
    let user: CivitaiUser
    let stats: PostStats?
    let images: [CivitaiImage]?

    // Provide defaults for optional fields
    var safeStats: PostStats {
        stats ?? PostStats(cryCount: 0, likeCount: 0, heartCount: 0, laughCount: 0, commentCount: 0, dislikeCount: 0)
    }

    var safeImages: [CivitaiImage] {
        images ?? []
    }

    init(
        id: Int,
        nsfwLevel: Int,
        title: String?,
        imageCount: Int,
        user: CivitaiUser,
        stats: PostStats?,
        images: [CivitaiImage]?
    ) {
        self.id = id
        self.nsfwLevel = nsfwLevel
        self.title = title
        self.imageCount = imageCount
        self.user = user
        self.stats = stats
        self.images = images
    }
}

struct PostStats: Codable, Hashable {
    let cryCount: Int
    let likeCount: Int
    let heartCount: Int
    let laughCount: Int
    let commentCount: Int
    let dislikeCount: Int
}
