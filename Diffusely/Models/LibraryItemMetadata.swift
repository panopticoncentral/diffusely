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
    static let currentSchemaVersion = 4   // v3 added publishedAt; v4 added publishedAtBackfillAttemptedAt

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
    /// Set by `LibraryDateBackfillService` when an API call returns the image
    /// but with `publishedAt: null` (drafts, deleted/unpublished, moderation).
    /// Background backfill skips items with this stamp so we don't re-ask
    /// every Library visit forever. Only the user-initiated catchup path
    /// (opening the detail view, or an explicit refresh) retries.
    let publishedAtBackfillAttemptedAt: Date?
    let savedAt: Date
    let savedByAppVersion: String

    static func == (lhs: LibraryItemMetadata, rhs: LibraryItemMetadata) -> Bool {
        // `publishedAtBackfillAttemptedAt` is intentionally excluded: it's
        // bookkeeping for the background scanner, not a meaningful identity
        // field, and including it would make every backfill attempt look like
        // a "real change" to the index and trigger extra ingests.
        lhs.itemID == rhs.itemID
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.contentSHA256 == rhs.contentSHA256
            && lhs.mediaFileName == rhs.mediaFileName
            && lhs.savedAt == rhs.savedAt
            && lhs.publishedAt == rhs.publishedAt
    }

    /// Explicit memberwise init so the v4 `publishedAtBackfillAttemptedAt`
    /// field can default to nil — keeps every existing call site (save, tests,
    /// reconcile) source-compatible without sprinkling `attemptedAt: nil`
    /// everywhere.
    init(
        schemaVersion: Int,
        itemID: Int,
        sourcePostID: Int?,
        sourcePostTitle: String?,
        canonicalPostURL: String?,
        canonicalPageURL: String,
        sourceDomain: String,
        originalCDNURL: String,
        mediaType: LibraryMediaType,
        mediaFileName: String,
        fileByteSize: Int,
        contentSHA256: String,
        width: Int,
        height: Int,
        nsfwLevel: Int,
        author: LibraryAuthor,
        stats: ImageStats?,
        generationData: GenerationData?,
        publishedAt: Date?,
        publishedAtBackfillAttemptedAt: Date? = nil,
        savedAt: Date,
        savedByAppVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.sourcePostID = sourcePostID
        self.sourcePostTitle = sourcePostTitle
        self.canonicalPostURL = canonicalPostURL
        self.canonicalPageURL = canonicalPageURL
        self.sourceDomain = sourceDomain
        self.originalCDNURL = originalCDNURL
        self.mediaType = mediaType
        self.mediaFileName = mediaFileName
        self.fileByteSize = fileByteSize
        self.contentSHA256 = contentSHA256
        self.width = width
        self.height = height
        self.nsfwLevel = nsfwLevel
        self.author = author
        self.stats = stats
        self.generationData = generationData
        self.publishedAt = publishedAt
        self.publishedAtBackfillAttemptedAt = publishedAtBackfillAttemptedAt
        self.savedAt = savedAt
        self.savedByAppVersion = savedByAppVersion
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
