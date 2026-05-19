import Foundation
import SwiftData

@Model
final class PersistedCollection {
    @Attribute(.unique) var id: Int
    var name: String
    var collectionType: String  // "Image" or "Post"
    var lastSyncStarted: Date?
    var lastSyncCompleted: Date?
    var syncCursor: String?  // nil means sync complete or not started
    var isSyncing: Bool = false
    var syncGeneration: Int = 0  // bumped at the start of each fresh full pass; items not stamped with the current value are swept on completion

    // MARK: - User-list cache metadata (decoupled from the contents-sync fields above)

    var collectionDescription: String?
    var imageCount: Int?
    // Raw cover-image fields so toCivitaiCollection() can rebuild a faithful
    // CollectionCoverImage (CollectionCard.displayImageURL depends on fullImageURL).
    var coverImageId: Int?
    var coverImageRelativePath: String?
    var coverImageNsfwLevel: Int?
    var coverImageWidth: Int?
    var coverImageHeight: Int?
    var coverImageHash: String?
    var ownerUserId: Int?
    var ownerUsername: String?
    var listOrder: Int = 0
    var isInUserList: Bool = false
    var lastListSyncStarted: Date?
    var lastListSyncCompleted: Date?
    var isListSyncing: Bool = false
    var listSyncGeneration: Int = 0    // pass generation stamped on this row when last upserted from a list fetch
    var lastSeenListGeneration: Int = 0  // generation in which this row was last observed in the user's list

    @Relationship(deleteRule: .cascade, inverse: \PersistedImage.collection)
    var images: [PersistedImage] = []

    @Relationship(deleteRule: .cascade, inverse: \PersistedPost.collection)
    var posts: [PersistedPost] = []

    init(id: Int, name: String, collectionType: String) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
    }

    convenience init(from collection: CivitaiCollection) {
        self.init(
            id: collection.id,
            name: collection.name,
            collectionType: collection.type ?? "Image"
        )
        applyDescriptiveMetadata(from: collection)
    }

    var itemCount: Int {
        collectionType == "Image" ? images.count : posts.count
    }

    /// Copies the non-identity descriptive fields from an API collection.
    /// Does NOT touch list-membership or any contents-sync state.
    private func applyDescriptiveMetadata(from collection: CivitaiCollection) {
        name = collection.name
        // Never clobber a good cached type with a nil one (basic list rows lack type).
        if let type = collection.type {
            collectionType = type
        }
        collectionDescription = collection.description
        imageCount = collection.imageCount
        coverImageId = collection.image?.id
        coverImageRelativePath = collection.image?.url
        coverImageNsfwLevel = collection.image?.nsfwLevel
        coverImageWidth = collection.image?.width
        coverImageHeight = collection.image?.height
        coverImageHash = collection.image?.hash
        ownerUserId = collection.user?.id
        ownerUsername = collection.user?.username
    }

    /// Marks this row as part of the user's collection list for `generation`
    /// and refreshes its descriptive metadata. Leaves contents-sync fields
    /// (`syncCursor`, `lastSyncCompleted`, `isSyncing`, `syncGeneration`) alone.
    func applyListMetadata(from collection: CivitaiCollection, order: Int, generation: Int) {
        applyDescriptiveMetadata(from: collection)
        listOrder = order
        isInUserList = true
        listSyncGeneration = generation
        lastSeenListGeneration = generation
    }

    /// Reconstructs the API model (including a faithful cover image) so the
    /// existing CivitaiCollection-typed UI and navigation keep working.
    func toCivitaiCollection() -> CivitaiCollection {
        let cover: CollectionCoverImage?
        if coverImageId != nil || coverImageRelativePath != nil {
            cover = CollectionCoverImage(
                id: coverImageId,
                url: coverImageRelativePath,
                nsfwLevel: coverImageNsfwLevel,
                width: coverImageWidth,
                height: coverImageHeight,
                hash: coverImageHash
            )
        } else {
            cover = nil
        }
        let owner = ownerUserId.map {
            CivitaiUser(id: $0, username: ownerUsername, image: nil)
        }
        return CivitaiCollection(
            id: id,
            name: name,
            description: collectionDescription,
            type: collectionType,
            imageCount: imageCount,
            image: cover,
            user: owner
        )
    }
}
