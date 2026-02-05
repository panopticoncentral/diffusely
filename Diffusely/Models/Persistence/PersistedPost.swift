import Foundation
import SwiftData

@Model
final class PersistedPost {
    @Attribute(.unique) var id: Int
    var nsfwLevel: Int
    var title: String?
    var imageCount: Int

    // Stats
    var likeCount: Int = 0
    var laughCount: Int = 0
    var heartCount: Int = 0
    var cryCount: Int = 0
    var commentCount: Int = 0

    var collection: PersistedCollection?
    var author: PersistedAuthor?

    @Relationship(deleteRule: .cascade, inverse: \PersistedPostImage.post)
    var images: [PersistedPostImage] = []

    init(
        id: Int,
        nsfwLevel: Int,
        title: String?,
        imageCount: Int
    ) {
        self.id = id
        self.nsfwLevel = nsfwLevel
        self.title = title
        self.imageCount = imageCount
    }

    convenience init(from post: CivitaiPost) {
        self.init(
            id: post.id,
            nsfwLevel: post.nsfwLevel,
            title: post.title,
            imageCount: post.imageCount
        )

        if let stats = post.stats {
            self.likeCount = stats.likeCount
            self.laughCount = stats.laughCount
            self.heartCount = stats.heartCount
            self.cryCount = stats.cryCount
            self.commentCount = stats.commentCount
        }
    }

    func toCivitaiPost() -> CivitaiPost {
        CivitaiPost(
            id: id,
            nsfwLevel: nsfwLevel,
            title: title,
            imageCount: imageCount,
            user: author?.toCivitaiUser() ?? CivitaiUser(id: 0, username: nil, image: nil),
            stats: PostStats(
                cryCount: cryCount,
                likeCount: likeCount,
                heartCount: heartCount,
                laughCount: laughCount,
                commentCount: commentCount,
                dislikeCount: 0
            ),
            images: images.map { $0.toCivitaiImage() }
        )
    }
}

@Model
final class PersistedPostImage {
    @Attribute(.unique) var id: Int
    var url: String
    var width: Int
    var height: Int
    var nsfwLevel: Int
    var imageType: String

    var post: PersistedPost?

    init(id: Int, url: String, width: Int, height: Int, nsfwLevel: Int, imageType: String) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.nsfwLevel = nsfwLevel
        self.imageType = imageType
    }

    convenience init(from image: CivitaiImage) {
        self.init(
            id: image.id,
            url: image.detailURL,
            width: image.width,
            height: image.height,
            nsfwLevel: image.nsfwLevel,
            imageType: image.type
        )
    }

    func toCivitaiImage() -> CivitaiImage {
        CivitaiImage(
            id: id,
            url: url,
            width: width,
            height: height,
            nsfwLevel: nsfwLevel,
            type: imageType,
            postId: nil,
            user: nil,
            stats: nil
        )
    }
}
