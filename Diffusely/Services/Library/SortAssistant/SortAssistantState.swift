import Foundation

/// Sort Assistant rejection memory: which (item, album) suggestions and which
/// new-album proposals the user has declined, so re-runs don't resurface them.
/// Persisted as `sort-assistant-state.json` in the container — survives index
/// rebuilds and syncs across devices. Item ids are stringified for stable JSON
/// keys ([Int: …] would encode as a flat array).
struct SortAssistantState: Codable, Equatable {
    var schemaVersion: Int
    /// itemID (string) → rejected album UUID strings.
    var rejected: [String: [String]]
    /// itemIDs (strings) rejected as "new album" suggestions.
    var rejectedNewAlbum: [String]

    static let empty = SortAssistantState(schemaVersion: 1, rejected: [:], rejectedNewAlbum: [])

    func isRejected(itemID: Int, albumID: UUID) -> Bool {
        rejected[String(itemID)]?.contains(albumID.uuidString) ?? false
    }

    func isNewAlbumRejected(itemID: Int) -> Bool {
        rejectedNewAlbum.contains(String(itemID))
    }

    mutating func recordRejection(itemID: Int, albumID: UUID) {
        let key = String(itemID)
        var list = rejected[key] ?? []
        guard !list.contains(albumID.uuidString) else { return }
        list.append(albumID.uuidString)
        rejected[key] = list
    }

    mutating func recordNewAlbumRejection(itemID: Int) {
        let key = String(itemID)
        guard !rejectedNewAlbum.contains(key) else { return }
        rejectedNewAlbum.append(key)
    }
}

/// Coordinated reader/writer for the state file, mirroring `LibraryAlbumStore`:
/// synchronous `NSFileCoordinator` I/O that the CALLER must dispatch onto a
/// dedicated serial queue, never the cooperative pool or main actor
/// (grey-spinner rule).
struct SortAssistantStateStore {
    let itemsDirectory: URL

    static let fileName = "sort-assistant-state.json"

    private var url: URL {
        itemsDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Missing or unreadable file reads as `.empty` — losing rejection memory
    /// only means some declined suggestions reappear once; never fatal.
    func read() -> SortAssistantState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SortAssistantState.self, from: data) else {
            return .empty
        }
        return state
    }

    func write(_ state: SortAssistantState) throws {
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(state)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { dest in
            do { try json.write(to: dest, options: .atomic) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }
}
