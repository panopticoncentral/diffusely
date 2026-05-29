import Foundation

struct CollectionCoverImage: Codable, Hashable {
    let id: Int?
    let url: String?
    let nsfwLevel: Int?
    let width: Int?
    let height: Int?
    let hash: String?

    var fullImageURL: String? {
        guard let url = url, let id = id else { return nil }
        // The Civitai API does not tell us whether a collection cover is an image or a video,
        // so we always request a static JPEG frame: `transcode=true` + `anim=false` works for
        // both (no-op for image sources, frame extraction for video sources). `skip=4` avoids
        // an all-black opening frame on video sources and is ignored for images.
        return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/transcode=true,anim=false,skip=4,width=450,optimized=true/\(id).jpeg"
    }
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
