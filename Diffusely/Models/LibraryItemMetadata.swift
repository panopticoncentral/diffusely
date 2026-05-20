import Foundation

enum LibraryMediaType: String, Codable {
    case image
    case video

    var fileExtension: String {
        switch self {
        case .image: return "jpeg"
        case .video: return "mp4"
        }
    }
}

struct LibraryAuthor: Codable, Hashable {
    let id: Int?
    let username: String?
    let avatarURL: String?
}

/// Self-describing sidecar JSON written next to each saved media file. This is the
/// authoritative record for a library item: the SwiftData index is a disposable
/// cache rebuilt entirely from these files (including ones synced from other
/// devices), so every field needed to render and re-link an item lives here.
struct LibraryItemMetadata: Codable, Equatable {
    static let currentSchemaVersion = 3   // was 2

    var schemaVersion: Int
    /// Civitai image id. Also the filename stem for both the media and this JSON.
    let itemID: Int
    let sourcePostID: Int?
    /// Title of the source post, if the item belonged to one (best-effort).
    let sourcePostTitle: String?
    /// Canonical Civitai page for the source post, if any.
    let canonicalPostURL: String?
    /// Canonical Civitai page for the item, honoring the domain at save time.
    let canonicalPageURL: String
    /// Domain (civitai.com / civitai.red) selected when the item was saved.
    let sourceDomain: String
    /// Original full-resolution CDN URL the media was downloaded from.
    let originalCDNURL: String
    let mediaType: LibraryMediaType
    let mediaFileName: String
    let fileByteSize: Int
    /// SHA-256 of the media bytes for integrity checks after iCloud transfer.
    let contentSHA256: String
    let width: Int
    let height: Int
    let nsfwLevel: Int
    let author: LibraryAuthor
    let stats: ImageStats?
    let generationData: GenerationData?
    /// Original Civitai publish date. Nullable: absent in v2 sidecars and
    /// when the source image is itself missing it. Backfilled on demand
    /// via `LibraryDateBackfillService`.
    let publishedAt: Date?
    let savedAt: Date
    let savedByAppVersion: String

    static func == (lhs: LibraryItemMetadata, rhs: LibraryItemMetadata) -> Bool {
        lhs.itemID == rhs.itemID
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.contentSHA256 == rhs.contentSHA256
            && lhs.mediaFileName == rhs.mediaFileName
            && lhs.savedAt == rhs.savedAt
            && lhs.publishedAt == rhs.publishedAt
    }
}

extension LibraryItemMetadata {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
