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
        downloadStatus: LibraryDownloadStatus
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
            downloadStatus: downloadStatus
        )
    }

    var downloadStatus: LibraryDownloadStatus {
        get { LibraryDownloadStatus(rawValue: downloadStatusRaw) ?? .downloaded }
        set { downloadStatusRaw = newValue.rawValue }
    }

    var isVideo: Bool { mediaType == LibraryMediaType.video.rawValue }
}
