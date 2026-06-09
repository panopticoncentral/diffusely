import Foundation
import SwiftData

enum LibraryDownloadStatus: String, Codable {
    /// Media bytes are present locally (up to date).
    case downloaded
    /// Only the sidecar JSON is local; media is in iCloud and not downloaded.
    case evicted
    /// Media is currently downloading from iCloud.
    case downloading
}

/// Disposable local index row for fast grid querying. NOT the source of truth -
/// every field is derived from the sidecar JSON in the container and the whole
/// store can be rebuilt from it. Intentionally self-contained: no relationships
/// to the Civitai-collection models so it cannot destabilize the existing store.
@Model
final class PersistedLibraryItem {
    @Attribute(.unique) var itemID: Int
    var mediaType: String          // "image" | "video"
    var mediaFileName: String
    var width: Int
    var height: Int
    var nsfwLevel: Int
    var authorUsername: String?
    /// Avatar URL denormalized from the sidecar's LibraryAuthor.avatarURL.
    /// Drives author-grouped section headers; rebuilt by reconcile.
    var authorAvatarURL: String?
    var sourcePostID: Int?
    var canonicalPageURL: String
    var fileByteSize: Int
    var savedAt: Date
    /// Original Civitai publish date (denormalized from sidecar). Nullable
    /// for items predating schema v3; backfilled on demand.
    var publishedAt: Date?
    /// First `Checkpoint`-typed resource in the sidecar's generationData.
    /// Nullable when generation data is missing or has no checkpoint
    /// (typical for videos and bare uploads).
    var checkpointName: String?
    var lastAccessedAt: Date
    var downloadStatusRaw: String
    /// True while this item still needs a publish-date backfill: it has no
    /// `publishedAt` AND the background scan hasn't yet recorded an attempt.
    /// Lets the `LibraryView` gate skip the expensive sidecar directory walk
    /// when nothing is pending. Defaults to `true` so a freshly-migrated store
    /// over-runs the backfill once (harmless) rather than wrongly skipping it
    /// before the first reconcile re-derives the flag. Kept in sync by
    /// `LibraryIndexService.apply`.
    var needsDateBackfill: Bool = true
    /// Denormalized album membership: the item's album UUIDs joined by U+001F
    /// (a delimiter that can't appear in a UUID string). Kept in sync with the
    /// sidecar's `albumIDs` by the convenience init and `LibraryIndexService.apply`.
    /// Stored as a scalar string (not a relationship) so it fits the existing
    /// fetchAll()+in-memory-filter read path. Defaults to "" for v4 rows.
    var albumIDsJoined: String = ""

    init(
        itemID: Int,
        mediaType: String,
        mediaFileName: String,
        width: Int,
        height: Int,
        nsfwLevel: Int,
        authorUsername: String?,
        authorAvatarURL: String?,
        sourcePostID: Int?,
        canonicalPageURL: String,
        fileByteSize: Int,
        savedAt: Date,
        publishedAt: Date?,
        checkpointName: String?,
        lastAccessedAt: Date,
        downloadStatus: LibraryDownloadStatus,
        needsDateBackfill: Bool,
        albumIDsJoined: String = ""
    ) {
        self.itemID = itemID
        self.mediaType = mediaType
        self.mediaFileName = mediaFileName
        self.width = width
        self.height = height
        self.nsfwLevel = nsfwLevel
        self.authorUsername = authorUsername
        self.authorAvatarURL = authorAvatarURL
        self.sourcePostID = sourcePostID
        self.canonicalPageURL = canonicalPageURL
        self.fileByteSize = fileByteSize
        self.savedAt = savedAt
        self.publishedAt = publishedAt
        self.checkpointName = checkpointName
        self.lastAccessedAt = lastAccessedAt
        self.downloadStatusRaw = downloadStatus.rawValue
        self.needsDateBackfill = needsDateBackfill
        self.albumIDsJoined = albumIDsJoined
    }

    /// Single source of truth for "this item still needs a publish-date
    /// backfill": no date yet, and the background scan hasn't recorded an
    /// attempt. Mirrors the pending filter in `FileLibraryBackfillSidecarStore`.
    static func computeNeedsDateBackfill(for metadata: LibraryItemMetadata) -> Bool {
        metadata.publishedAt == nil && metadata.publishedAtBackfillAttemptedAt == nil
    }

    convenience init(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
        let checkpoint = metadata.generationData?
            .resources?
            .first(where: { $0.modelType == "Checkpoint" })?
            .modelName
        self.init(
            itemID: metadata.itemID,
            mediaType: metadata.mediaType.rawValue,
            mediaFileName: metadata.mediaFileName,
            width: metadata.width,
            height: metadata.height,
            nsfwLevel: metadata.nsfwLevel,
            authorUsername: metadata.author.username,
            authorAvatarURL: metadata.author.avatarURL,
            sourcePostID: metadata.sourcePostID,
            canonicalPageURL: metadata.canonicalPageURL,
            fileByteSize: metadata.fileByteSize,
            savedAt: metadata.savedAt,
            publishedAt: metadata.publishedAt,
            checkpointName: checkpoint,
            lastAccessedAt: metadata.savedAt,
            downloadStatus: downloadStatus,
            needsDateBackfill: Self.computeNeedsDateBackfill(for: metadata),
            albumIDsJoined: Self.join(metadata.albumIDs)
        )
    }

    var downloadStatus: LibraryDownloadStatus {
        get { LibraryDownloadStatus(rawValue: downloadStatusRaw) ?? .downloaded }
        set { downloadStatusRaw = newValue.rawValue }
    }

    var isVideo: Bool { mediaType == LibraryMediaType.video.rawValue }

    static let albumDelimiter = "\u{1f}"

    static func join(_ ids: [String]) -> String {
        ids.joined(separator: albumDelimiter)
    }

    var albumIDs: [String] {
        get {
            albumIDsJoined.isEmpty ? [] : albumIDsJoined.components(separatedBy: Self.albumDelimiter)
        }
        set { albumIDsJoined = Self.join(newValue) }
    }

    var isInAnyAlbum: Bool { !albumIDsJoined.isEmpty }

    func belongs(toAlbum id: String) -> Bool { albumIDs.contains(id) }
}
