import Foundation

struct CivitaiImage: Codable, Identifiable, Hashable {
    let id: Int
    private let url: String // Make this private since we need to construct the full URL
    let width: Int
    let height: Int
    let nsfwLevel: Int
    let type: String
    let postId: Int?  // The post that the image belongs to
    let user: CivitaiUser?  // Made optional since it's not always present in posts
    let stats: ImageStats?  // Made optional since it's not always present in posts
    let thumbnailUrl: String?  // API-provided thumbnail URL for videos

    var detailURL: String {
        // If url is already a full URL (from persistence), return it directly
        if url.hasPrefix("https://") {
            return url
        }
        // Otherwise construct the URL from the UUID
        if isVideo {
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/transcode=true,width=450,optimized=true/\(id).mp4"
        } else {
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(url)/anim=false,width=450,optimized=true/\(id).jpeg"
        }
    }

    var isVideo: Bool {
        return type == "video"
    }

    /// Extracts the UUID from the url field (handles both raw UUID and full URLs from persistence)
    private var imageUUID: String {
        // If url is already a full URL (from persistence), extract the UUID
        if url.hasPrefix("https://image.civitai.com/") {
            // URL format: https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/{uuid}/params/filename
            let components = url.components(separatedBy: "/")
            // UUID is typically at index 4 (after protocol, empty, domain, path)
            if components.count > 4 {
                return components[4]
            }
        }
        // Otherwise, url is already just the UUID
        return url
    }

    /// Returns a static image thumbnail URL, even for videos (for use in collection previews)
    var thumbnailURL: String {
        // For videos, use API-provided thumbnail if available
        if isVideo, let apiThumbnail = thumbnailUrl {
            return apiThumbnail
        }
        // For videos without API thumbnail, use transcode + anim=false + skip to extract a frame
        if isVideo {
            return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(imageUUID)/transcode=true,anim=false,skip=4,width=450/\(id).jpeg"
        }
        // For images, construct the standard image URL
        return "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/\(imageUUID)/anim=false,width=450,optimized=true/\(id).jpeg"
    }

    /// Creates a CivitaiImage with a pre-constructed full URL (used when restoring from persistence)
    init(
        id: Int,
        url: String,
        width: Int,
        height: Int,
        nsfwLevel: Int,
        type: String,
        postId: Int?,
        user: CivitaiUser?,
        stats: ImageStats?,
        thumbnailUrl: String? = nil
    ) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.nsfwLevel = nsfwLevel
        self.type = type
        self.postId = postId
        self.user = user
        self.stats = stats
        self.thumbnailUrl = thumbnailUrl
    }
}

struct ImageStats: Codable, Hashable {
    let likeCountAllTime: Int
    let laughCountAllTime: Int
    let heartCountAllTime: Int
    let cryCountAllTime: Int
    let commentCountAllTime: Int
    let collectedCountAllTime: Int
    let tippedAmountCountAllTime: Int
    let dislikeCountAllTime: Int
    let viewCountAllTime: Int
}
