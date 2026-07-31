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

/// Coordinated reader/writer for the state file, routed through
/// `LibraryFileStore`'s aux helpers (mirrors `LibraryAlbumStore`): plaintext
/// mode still produces/reads the literal `sort-assistant-state.json` name
/// (byte-identical to the pre-store implementation), while an encrypted store
/// seals the same JSON under an opaque `.x` name. The `write` call is
/// synchronous coordinated I/O that the CALLER must dispatch onto a dedicated
/// serial queue, never the cooperative pool or main actor (grey-spinner rule).
struct SortAssistantStateStore {
    let store: LibraryFileStore

    static let fileName = "sort-assistant-state.json"

    init(store: LibraryFileStore) {
        self.store = store
    }

    /// Convenience for callers/tests that haven't been migrated to the
    /// vault-aware store yet: builds a passthrough store (`crypto: nil`) over
    /// `itemsDirectory`, preserving today's plaintext layout exactly. Mirrors
    /// `LibraryFileWriter(itemsDirectory:)`.
    init(itemsDirectory: URL) {
        self.init(store: LibraryFileStore(itemsDirectory: itemsDirectory, crypto: nil))
    }

    /// Missing or unreadable file reads as `.empty` — losing rejection memory
    /// only means some declined suggestions reappear once; never fatal. Also
    /// what a locked vault reads as (its passthrough store can't find the real
    /// opaque file), which is an acceptable degrade for this best-effort state.
    func read() -> SortAssistantState {
        guard let data = store.readAux(name: Self.fileName),
              let state = try? JSONDecoder().decode(SortAssistantState.self, from: data) else {
            return .empty
        }
        return state
    }

    func write(_ state: SortAssistantState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(state)
        try store.writeAux(json, name: Self.fileName)
    }
}
