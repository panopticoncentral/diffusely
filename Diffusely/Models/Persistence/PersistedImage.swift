import Foundation
import SwiftData

@Model
final class PersistedImage {
    @Attribute(.unique) var id: Int
    var url: String
    var width: Int
    var height: Int
    var nsfwLevel: Int
    var imageType: String  // "image" or "video"
    var postId: Int?

    // Stats
    var likeCount: Int = 0
    var laughCount: Int = 0
    var heartCount: Int = 0
    var cryCount: Int = 0
    var commentCount: Int = 0
    var collectedCount: Int = 0

    var collection: PersistedCollection?
    var author: PersistedAuthor?

    init(
        id: Int,
        url: String,
        width: Int,
        height: Int,
        nsfwLevel: Int,
        imageType: String,
        postId: Int?
    ) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.nsfwLevel = nsfwLevel
        self.imageType = imageType
        self.postId = postId
    }

    convenience init(from image: CivitaiImage) {
        self.init(
            id: image.id,
            url: image.detailURL,
            width: image.width,
            height: image.height,
            nsfwLevel: image.nsfwLevel,
            imageType: image.type,
            postId: image.postId
        )

        if let stats = image.stats {
            self.likeCount = stats.likeCountAllTime
            self.laughCount = stats.laughCountAllTime
            self.heartCount = stats.heartCountAllTime
            self.cryCount = stats.cryCountAllTime
            self.commentCount = stats.commentCountAllTime
            self.collectedCount = stats.collectedCountAllTime
        }
    }

    func toCivitaiImage() -> CivitaiImage {
        CivitaiImage(
            id: id,
            url: url,
            width: width,
            height: height,
            nsfwLevel: nsfwLevel,
            type: imageType,
            postId: postId,
            user: author?.toCivitaiUser(),
            stats: ImageStats(
                likeCountAllTime: likeCount,
                laughCountAllTime: laughCount,
                heartCountAllTime: heartCount,
                cryCountAllTime: cryCount,
                commentCountAllTime: commentCount,
                collectedCountAllTime: collectedCount,
                tippedAmountCountAllTime: 0,
                dislikeCountAllTime: 0,
                viewCountAllTime: 0
            )
        )
    }

    var isVideo: Bool {
        imageType == "video"
    }
}
