import Foundation
import CryptoKit

enum LibrarySaveError: LocalizedError {
    case alreadySaved
    case downloadFailed
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .alreadySaved: return "Already in your library."
        case .downloadFailed: return "Couldn't download the original media. Check your connection and try again."
        case .writeFailed(let error): return "Couldn't save to your library: \(error.localizedDescription)"
        }
    }
}

/// Performs the atomic on-disk write of a library item: media file first, sidecar
/// JSON last (JSON presence is the "fully saved" commit marker). Pure file I/O so
/// it can be unit-tested against a temporary directory without iCloud.
struct LibraryFileWriter {
    let itemsDirectory: URL

    func mediaURL(for metadata: LibraryItemMetadata) -> URL {
        itemsDirectory.appendingPathComponent(metadata.mediaFileName, isDirectory: false)
    }

    func metadataURL(forItemID id: Int) -> URL {
        itemsDirectory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    func itemExists(itemID: Int) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(forItemID: itemID).path)
    }

    /// Moves the downloaded media into place, then writes the JSON. If anything
    /// fails the JSON is never written, so a partial item is never visible.
    func commit(metadata: LibraryItemMetadata, mediaTempURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)

        let coordinator = NSFileCoordinator()
        let finalMediaURL = mediaURL(for: metadata)
        let finalMetadataURL = metadataURL(forItemID: metadata.itemID)

        var coordinationError: NSError?
        var thrown: Error?

        coordinator.coordinate(
            writingItemAt: finalMediaURL,
            options: .forReplacing,
            error: &coordinationError
        ) { destination in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: mediaTempURL, to: destination)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }

        let json = try LibraryItemMetadata.encoder().encode(metadata)
        coordinator.coordinate(
            writingItemAt: finalMetadataURL,
            options: .forReplacing,
            error: &coordinationError
        ) { destination in
            do {
                try json.write(to: destination, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    /// Atomically rewrites the sidecar JSON for an already-committed item.
    /// Used by `LibraryDateBackfillService` to add fields (like `publishedAt`)
    /// onto old sidecars without touching the media file.
    func rewriteMetadata(_ metadata: LibraryItemMetadata) throws {
        let json = try LibraryItemMetadata.encoder().encode(metadata)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        let target = metadataURL(forItemID: metadata.itemID)

        coordinator.coordinate(
            writingItemAt: target,
            options: .forReplacing,
            error: &coordinationError
        ) { destination in
            do {
                try json.write(to: destination, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }
}

/// Orchestrates saving a feed item into the personal library: download the
/// original, fetch generation data (best effort), then atomically write the
/// media + sidecar JSON and update the local index. Work runs in a service-owned
/// task so it survives the originating view being dismissed.
@MainActor
final class LibrarySaveService: ObservableObject {
    static let shared = LibrarySaveService()

    @Published private(set) var inFlight: Set<Int> = []
    @Published var lastError: LibrarySaveError?

    weak var indexService: LibraryIndexService?

    private var tasks: [Int: Task<Void, Never>] = [:]
    private let civitaiService = CivitaiService()

    init() {}

    func isSaving(itemID: Int) -> Bool { inFlight.contains(itemID) }

    /// True while any image belonging to the post is still being saved.
    func isSavingPost(_ post: CivitaiPost) -> Bool {
        post.safeImages.contains { inFlight.contains($0.id) }
    }

    /// Saves every image/video in a post as individual library items. They share
    /// the same `sourcePostID`/title so the post can be reconstructed; the post
    /// title is passed through to avoid a per-image post fetch.
    func savePost(_ post: CivitaiPost) {
        for image in post.safeImages {
            save(image, knownPostTitle: post.title)
        }
    }

    func save(_ image: CivitaiImage, knownPostTitle: String? = nil) {
        let itemID = image.id
        guard !inFlight.contains(itemID) else { return }

        let domain = DomainManager.shared.domain.rawValue
        let canonicalPageURL = "https://\(domain)/images/\(itemID)"
        let canonicalPostURL = image.postId.map { "https://\(domain)/posts/\($0)" }
        let originalCDNURL = image.originalURL
        let mediaType: LibraryMediaType = image.isVideo ? .video : .image
        let author = LibraryAuthor(
            id: image.user?.id,
            username: image.user?.username,
            avatarURL: image.user?.image
        )

        inFlight.insert(itemID)
        lastError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performSave(
                    itemID: itemID,
                    image: image,
                    originalCDNURL: originalCDNURL,
                    canonicalPageURL: canonicalPageURL,
                    canonicalPostURL: canonicalPostURL,
                    knownPostTitle: knownPostTitle,
                    sourceDomain: domain,
                    mediaType: mediaType,
                    author: author
                )
            } catch let error as LibrarySaveError {
                self.lastError = error
            } catch {
                self.lastError = .writeFailed(error)
            }
            self.inFlight.remove(itemID)
            self.tasks[itemID] = nil
        }
        tasks[itemID] = task
    }

    private func performSave(
        itemID: Int,
        image: CivitaiImage,
        originalCDNURL: String,
        canonicalPageURL: String,
        canonicalPostURL: String?,
        knownPostTitle: String?,
        sourceDomain: String,
        mediaType: LibraryMediaType,
        author: LibraryAuthor
    ) async throws {
        let itemsDirectory = try await LibraryContainer.shared.itemsDirectory()
        let writer = LibraryFileWriter(itemsDirectory: itemsDirectory)

        if writer.itemExists(itemID: itemID) {
            throw LibrarySaveError.alreadySaved
        }

        guard let url = URL(string: originalCDNURL) else {
            throw LibrarySaveError.downloadFailed
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw LibrarySaveError.downloadFailed
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
        let byteSize = (attrs?[.size] as? Int) ?? 0
        let sha = Self.sha256Hex(ofFileAt: tempURL) ?? ""

        let generationData = try? await civitaiService.fetchGenerationData(imageId: itemID)

        // Resolve the post title: use the one passed in (saving a whole post), or
        // best-effort fetch the post for a standalone image that belongs to one.
        var postTitle = knownPostTitle
        if postTitle == nil, let postID = image.postId {
            postTitle = try? await civitaiService.getPost(postId: postID).title
        }

        let metadata = LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: itemID,
            sourcePostID: image.postId,
            sourcePostTitle: postTitle,
            canonicalPostURL: canonicalPostURL,
            canonicalPageURL: canonicalPageURL,
            sourceDomain: sourceDomain,
            originalCDNURL: originalCDNURL,
            mediaType: mediaType,
            mediaFileName: "\(itemID).\(mediaType.fileExtension)",
            fileByteSize: byteSize,
            contentSHA256: sha,
            width: image.width,
            height: image.height,
            nsfwLevel: image.nsfwLevel,
            author: author,
            stats: image.stats,
            generationData: generationData,
            publishedAt: image.publishedAtDate,
            savedAt: Date(),
            savedByAppVersion: Self.appVersion
        )

        do {
            try writer.commit(metadata: metadata, mediaTempURL: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw LibrarySaveError.writeFailed(error)
        }

        if let indexService {
            await indexService.ingest(metadata: metadata, downloadStatus: .downloaded)
        }
    }

    // MARK: - Helpers

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
