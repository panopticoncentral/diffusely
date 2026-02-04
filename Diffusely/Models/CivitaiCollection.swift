import Foundation

struct CollectionCoverImage: Codable, Hashable {
    let id: Int?
    let url: String?
    let nsfwLevel: Int?
    let width: Int?
    let height: Int?
    let hash: String?
}

struct CivitaiCollection: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let type: String?  // "Article", "Post", "Image", "Model"
    let imageCount: Int?
    let image: CollectionCoverImage?
    let user: CivitaiUser?

    var coverImageURL: String? {
        image?.url
    }
}
