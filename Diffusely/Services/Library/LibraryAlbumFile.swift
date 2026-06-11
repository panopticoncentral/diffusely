import Foundation

/// LLM-distilled description of what an album contains (Sort Assistant).
/// Stored on the album file so it syncs across devices and survives index
/// rebuilds. `memberCount` is the number of prompt-bearing members when the
/// profile was built — the staleness baseline ("rebuild when membership has
/// doubled").
struct AlbumAIProfile: Codable, Equatable {
    var text: String
    var builtAt: Date
    var memberCount: Int
}

/// Self-describing metadata file for one album, written as `album-{uuid}.json`
/// in the iCloud container. The album's existence record — it carries only
/// identity, name, and creation date. Membership is NOT here; it lives on each
/// item's sidecar (`LibraryItemMetadata.albumIDs`). Like the item sidecar, this
/// is the source of truth; `PersistedAlbum` is a disposable index rebuilt from it.
struct LibraryAlbumFile: Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// Optional owner-written description; sharpens Sort Assistant profiles.
    var userDescription: String?
    /// LLM-built content profile (Sort Assistant). Nil until first built.
    var aiProfile: AlbumAIProfile?

    init(id: UUID, name: String, createdAt: Date,
         userDescription: String? = nil, aiProfile: AlbumAIProfile? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.userDescription = userDescription
        self.aiProfile = aiProfile
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

/// Coordinated reader/writer for album files in the container. Directory-injected
/// so it is unit-testable against a temp directory without iCloud. The write/delete
/// use `NSFileCoordinator` exactly like `LibraryFileWriter`. The `write`/`delete`
/// calls are synchronous coordinated file I/O; the caller (`LibraryAlbumService`,
/// added later) MUST dispatch them onto a dedicated serial queue, never the
/// cooperative pool or main actor, to avoid the grey-spinner cooperative-pool
/// starvation regression.
struct LibraryAlbumStore {
    let itemsDirectory: URL

    static let fileNamePrefix = "album-"

    static func fileName(for id: UUID) -> String { "\(fileNamePrefix)\(id.uuidString).json" }

    /// Recovers the album id from a filename without reading contents. Returns nil
    /// for non-album json (e.g. item sidecars named `{int}.json`).
    static func albumID(fromFileName name: String) -> UUID? {
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(".json") else { return nil }
        let start = name.index(name.startIndex, offsetBy: fileNamePrefix.count)
        let end = name.index(name.endIndex, offsetBy: -".json".count)
        return UUID(uuidString: String(name[start..<end]))
    }

    private func url(for id: UUID) -> URL {
        itemsDirectory.appendingPathComponent(Self.fileName(for: id), isDirectory: false)
    }

    func read(id: UUID) -> LibraryAlbumFile? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data)
    }

    func write(_ file: LibraryAlbumFile) throws {
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let json = try LibraryAlbumFile.encoder().encode(file)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url(for: file.id), options: .forReplacing, error: &coordinationError) { dest in
            do { try json.write(to: dest, options: .atomic) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    func delete(id: UUID) {
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let coordinator = NSFileCoordinator()
        // Best-effort delete: coordination/removal errors are intentionally
        // ignored (the file is usually already gone), matching LibraryStore.deleteFiles.
        var err: NSError?
        coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }
}
