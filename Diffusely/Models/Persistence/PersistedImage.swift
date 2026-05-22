import Foundation
import SwiftData

@Model
final class PersistedImage {
    // Deliberately NOT `@Attribute(.unique)`: an image can belong to several
    // collections on Civitai, and each collection caches its own row (the
    // `collection` reference below is to-one). A global unique constraint would
    // collapse those into a single row that could only point at one collection,
    // making a multi-collection image vanish from every collection but the last
    // one synced.
    var id: Int
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

    var publishedAt: Date?

    var collection: PersistedCollection?
    var author: PersistedAuthor?

    // Generation of the most recent sync pass that observed this item; used for mark-and-sweep cleanup.
    var lastSeenGeneration: Int = 0

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

        self.publishedAt = image.publishedAtDate
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
            ),
            publishedAt: formatCivitaiDate(publishedAt)
        )
    }

    var isVideo: Bool {
        imageType == "video"
    }
}
