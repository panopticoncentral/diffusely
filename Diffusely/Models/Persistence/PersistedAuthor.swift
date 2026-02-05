import Foundation
import SwiftData

@Model
final class PersistedAuthor {
    @Attribute(.unique) var id: Int
    var username: String?
    var imageURL: String?

    @Relationship(inverse: \PersistedImage.author)
    var images: [PersistedImage] = []

    @Relationship(inverse: \PersistedPost.author)
    var posts: [PersistedPost] = []

    init(id: Int, username: String?, imageURL: String?) {
        self.id = id
        self.username = username
        self.imageURL = imageURL
    }

    convenience init(from user: CivitaiUser) {
        self.init(id: user.id, username: user.username, imageURL: user.image)
    }

    func toCivitaiUser() -> CivitaiUser {
        CivitaiUser(id: id, username: username, image: imageURL)
    }
}
