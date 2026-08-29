import Foundation

/// A tag the user has chosen to follow. Civitai has no server-side tag
/// following, so this list is purely local: an id (what feeds filter by) and
/// the name we last saw for it (what the UI labels it with).
struct FollowedTag: Codable, Identifiable, Hashable {
    let id: Int
    let name: String

    /// Alphabetical (case-insensitive), ties broken by id so the order is
    /// stable across launches. Mirrors `FollowedUserRow.sorted`.
    static func sorted(_ tags: [FollowedTag]) -> [FollowedTag] {
        tags.sorted { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            if order == .orderedSame { return a.id < b.id }
            return order == .orderedAscending
        }
    }
}

/// The user's followed tags, persisted in `UserDefaults`.
///
/// `UserDefaults` rather than SwiftData because this is a short list of
/// scalars that is purely local user state; the SwiftData store in this app
/// is a cache of server data, which this is not.
///
/// Observable and shared via `.shared` so the tag chips on a detail view and
/// the Tags list stay in sync without threading a binding between them; the
/// `defaults` initializer exists so tests can use a scratch suite.
@MainActor
final class FollowedTagsStore: ObservableObject {
    static let shared = FollowedTagsStore()

    static let storageKey = "followedTags"

    @Published private(set) var tags: [FollowedTag] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tags = Self.load(from: defaults)
    }

    func isFollowing(id: Int) -> Bool {
        tags.contains { $0.id == id }
    }

    /// Adds `tag`, replacing any existing entry with the same id so a tag
    /// renamed on the server picks up its current name.
    func follow(_ tag: FollowedTag) {
        var updated = tags.filter { $0.id != tag.id }
        updated.append(tag)
        apply(updated)
    }

    func unfollow(id: Int) {
        let updated = tags.filter { $0.id != id }
        guard updated.count != tags.count else { return }
        apply(updated)
    }

    private func apply(_ updated: [FollowedTag]) {
        tags = FollowedTag.sorted(updated)
        save()
    }

    private func save() {
        if tags.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(tags) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Unreadable or foreign data degrades to "no follows" rather than
    /// trapping — this runs during view construction at launch.
    private static func load(from defaults: UserDefaults) -> [FollowedTag] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FollowedTag].self, from: data)
        else { return [] }
        return FollowedTag.sorted(decoded)
    }
}
