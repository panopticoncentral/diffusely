import Foundation
import Nuke
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
/// JSON last (JSON presence is the "fully saved" commit marker). Delegates all
/// actual I/O to a `LibraryFileStore`, which is a pure passthrough to today's
/// `<id>.json` / `<id>.<ext>` layout when unencrypted, so this remains
/// unit-testable against a temporary directory without iCloud.
struct LibraryFileWriter {
    let store: LibraryFileStore

    init(store: LibraryFileStore) {
        self.store = store
    }

    /// Convenience for the (still-plaintext) call sites that haven't been
    /// migrated to the vault-backed store yet: builds a passthrough store
    /// over `itemsDirectory`, preserving today's behavior exactly.
    init(itemsDirectory: URL) {
        self.init(store: LibraryFileStore(itemsDirectory: itemsDirectory, crypto: nil))
    }

    var itemsDirectory: URL { store.itemsDirectory }

    func mediaURL(for metadata: LibraryItemMetadata) -> URL {
        store.mediaURL(itemID: metadata.itemID, plaintextExtension: metadata.mediaType.fileExtension)
    }

    func metadataURL(forItemID id: Int) -> URL {
        store.metadataURL(itemID: id)
    }

    func itemExists(itemID: Int) -> Bool {
        store.readMetadata(itemID: itemID) != nil
    }

    /// Writes the media into place, then writes the JSON. If anything fails
    /// the JSON is never written, so a partial item is never visible.
    func commit(metadata: LibraryItemMetadata, mediaTempURL: URL) throws {
        let mediaBytes = try Data(contentsOf: mediaTempURL)
        try store.writeMedia(mediaBytes, itemID: metadata.itemID,
                              plaintextExtension: metadata.mediaType.fileExtension)
        try? FileManager.default.removeItem(at: mediaTempURL)

        let json = try LibraryItemMetadata.encoder().encode(metadata)   // JSON last = commit marker
        try store.writeMetadata(json, itemID: metadata.itemID)
    }

    /// Reads and decodes the sidecar for an already-committed item, if present.
    func readMetadata(itemID id: Int) -> LibraryItemMetadata? {
        guard let data = store.readMetadata(itemID: id) else { return nil }
        return try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
    }

    /// Atomically rewrites the sidecar JSON for an already-committed item.
    /// Used by `LibraryDateBackfillService` to add fields (like `publishedAt`)
    /// onto old sidecars without touching the media file.
    func rewriteMetadata(_ metadata: LibraryItemMetadata) throws {
        let json = try LibraryItemMetadata.encoder().encode(metadata)
        try store.writeMetadata(json, itemID: metadata.itemID)
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

    /// Resolves the vault's current lock state + a store bound to it, in one
    /// atomic snapshot (state and store both come from the same underlying
    /// `LibraryVault.snapshot()`, so they can never disagree — see
    /// `LibraryVaultProvider.reconcileContext()`'s doc comment for the TOCTOU
    /// this closes). Defaults to the process-wide `LibraryVaultProvider.shared`
    /// singleton so production call sites need no change; overridable so tests
    /// can drive `.locked` without touching the shared singleton, which would
    /// leak into every other test in the process (mirrors the seam on
    /// `LibraryAlbumService` / `FileLibraryBackfillSidecarStore`).
    private let resolveVaultContext: () async -> (state: LibraryVault.State, store: LibraryFileStore)

    init(
        resolveVaultContext: @escaping () async -> (state: LibraryVault.State, store: LibraryFileStore) = {
            await LibraryVaultProvider.shared.reconcileContext()
        }
    ) {
        self.resolveVaultContext = resolveVaultContext
    }

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
            // Post-endpoint image objects don't carry `publishedAt` (only the
            // post does), so pass the post's date down as a fallback. Without
            // this, every post-saved image would be written with a nil date and
            // need a `LibraryDateBackfillService` round-trip to fill it in.
            save(image, knownPostTitle: post.title, knownPublishedAt: post.publishedAtDate)
        }
    }

    func save(_ image: CivitaiImage, knownPostTitle: String? = nil, knownPublishedAt: Date? = nil) {
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
                    knownPublishedAt: knownPublishedAt,
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

    /// Internal (not `private`) so tests can drive it directly with an
    /// injected `resolveVaultContext`, without going through the fire-and-forget
    /// `save()` wrapper or a real network download.
    func performSave(
        itemID: Int,
        image: CivitaiImage,
        originalCDNURL: String,
        canonicalPageURL: String,
        canonicalPostURL: String?,
        knownPostTitle: String?,
        knownPublishedAt: Date?,
        sourceDomain: String,
        mediaType: LibraryMediaType,
        author: LibraryAuthor
    ) async throws {
        // Resolve up front so a failure (iCloud unavailable, disk full, etc.)
        // fails this save immediately. `LibraryVaultProvider.fileStore()`
        // deliberately swallows that same failure and falls back to a temp
        // scratch store (see its doc comment) so the vault gate never
        // crashes; this save path wants the original fail-fast behavior
        // instead of silently writing into that scratch directory.
        _ = try await LibraryContainer.shared.itemsDirectory()

        // Atomic (state, store) snapshot — NOT a separate `fileStore()` call —
        // so the locked-or-not decision and the store used to write can never
        // disagree (the TOCTOU `reconcileContext()` closes; see its doc
        // comment). A configured-but-locked vault has no DEK, so writing would
        // otherwise silently fall back to a plaintext passthrough store over
        // what is really an encrypted container (spec §4 forbids this).
        // `.notConfigured`/`.unlocked` are unaffected: they proceed exactly as
        // before this guard existed.
        let vaultContext = await resolveVaultContext()
        guard vaultContext.state != .locked else {
            throw LibraryBackfillSidecarStoreError.vaultLocked
        }
        let writer = LibraryFileWriter(store: vaultContext.store)

        if writer.itemExists(itemID: itemID) {
            throw LibrarySaveError.alreadySaved
        }

        guard let url = URL(string: originalCDNURL) else {
            throw LibrarySaveError.downloadFailed
        }

        let (tempURL, response) = try await URLSession.civitai.download(from: url)
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
            publishedAt: image.publishedAtDate ?? knownPublishedAt,
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

        // Prime Nuke's cache now, while the original is local — free, no extra
        // download. The first grid appearance then hits the cache instead of the
        // CDN-first tier. Off the main actor (ImageIO / AVAssetImageGenerator).
        // Resolved via the writer/store (not a bare itemsDirectory + filename
        // join) so this still finds the file when the store is encrypted and
        // the on-disk name is an opaque token rather than "<id>.<ext>".
        let finalMediaURL = writer.mediaURL(for: metadata)
        let isVideo = metadata.mediaType == .video
        if let thumb = await LibraryImageRequest.thumbnailImage(
            localURL: finalMediaURL, isVideo: isVideo, maxDimension: LibraryImageRequest.gridDimension) {
            let request = LibraryImageRequest.request(
                itemID: metadata.itemID, mediaFileName: metadata.mediaFileName,
                isVideo: isVideo, maxDimension: LibraryImageRequest.gridDimension)
            ImagePipeline.shared.cache.storeCachedImage(
                ImageContainer(image: thumb), for: request, caches: .all)
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
