import Foundation

struct CivitaiCollection: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let type: String?  // "Article", "Post", "Image", "Model"
    let imageCount: Int?
    let coverImage: String?  // URL to cover image
    let user: CivitaiUser?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case type
        case imageCount
        case coverImage = "image"
        case user
    }
}
