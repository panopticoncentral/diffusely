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
    }

    var itemCount: Int {
        collectionType == "Image" ? images.count : posts.count
    }
}
