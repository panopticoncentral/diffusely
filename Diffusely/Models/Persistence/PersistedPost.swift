import Foundation
import SwiftData

@Model
final class PersistedPost {
    // Deliberately NOT `@Attribute(.unique)`: a post can belong to several
    // collections on Civitai, and each collection caches its own row (the
    // `collection` reference below is to-one). A global unique constraint would
    // collapse those into a single row that could only point at one collection,
    // making a multi-collection post vanish from every collection but the last
    // one synced.
    var id: Int
    var nsfwLevel: Int
    var title: String?
    var imageCount: Int

    // Stats
    var likeCount: Int = 0
    var laughCount: Int = 0
    var heartCount: Int = 0
    var cryCount: Int = 0
    var commentCount: Int = 0

    var publishedAt: Date?

    var collection: PersistedCollection?
    var author: PersistedAuthor?

    // Generation of the most recent sync pass that observed this item; used for mark-and-sweep cleanup.
    var lastSeenGeneration: Int = 0

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

        self.publishedAt = post.publishedAtDate
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
            images: images.map { $0.toCivitaiImage() },
            publishedAt: formatCivitaiDate(publishedAt)
        )
    }
}

@Model
final class PersistedPostImage {
    // Not unique: its parent `PersistedPost` is duplicated per collection (see
    // PersistedPost.id), so the same image id recurs once per copy.
    var id: Int
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
        // The author lives on the parent `PersistedPost`; propagate it through
        // the existing back-reference so callers (notably `LibrarySaveService`)
        // capture the creator. Same goes for `postId` — without it, "Save to
        // Library" can't build a canonical post URL.
        CivitaiImage(
            id: id,
            url: url,
            width: width,
            height: height,
            nsfwLevel: nsfwLevel,
            type: imageType,
            postId: post?.id,
            user: post?.author?.toCivitaiUser(),
            stats: nil
        )
    }
}
