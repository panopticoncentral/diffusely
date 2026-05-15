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
    var sourcePostID: Int?
    var canonicalPageURL: String
    var fileByteSize: Int
    var savedAt: Date
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
        sourcePostID: Int?,
        canonicalPageURL: String,
        fileByteSize: Int,
        savedAt: Date,
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
        self.sourcePostID = sourcePostID
        self.canonicalPageURL = canonicalPageURL
        self.fileByteSize = fileByteSize
        self.savedAt = savedAt
        self.lastAccessedAt = lastAccessedAt
        self.downloadStatusRaw = downloadStatus.rawValue
    }

    convenience init(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
        self.init(
            itemID: metadata.itemID,
            mediaType: metadata.mediaType.rawValue,
            mediaFileName: metadata.mediaFileName,
            width: metadata.width,
            height: metadata.height,
            nsfwLevel: metadata.nsfwLevel,
            authorUsername: metadata.author.username,
            sourcePostID: metadata.sourcePostID,
            canonicalPageURL: metadata.canonicalPageURL,
            fileByteSize: metadata.fileByteSize,
            savedAt: metadata.savedAt,
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
