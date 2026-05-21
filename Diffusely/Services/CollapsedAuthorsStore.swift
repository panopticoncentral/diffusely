import Foundation

/// Persists, per collection, the set of author IDs the user has explicitly
/// collapsed in `CollectionDetailView`. Storing the *collapsed* set (rather
/// than the expanded set) keeps "expanded by default" behavior for free:
/// any author not in the set is treated as expanded.
///
/// State is scoped by collection ID because the same author can appear across
/// multiple collections, and collapse state should not leak between them.
enum CollapsedAuthorsStore {
    private static func key(for collectionId: Int) -> String {
        "collapsedAuthors.\(collectionId)"
    }

    static func load(collectionId: Int) -> Set<Int> {
        let stored = UserDefaults.standard.array(forKey: key(for: collectionId)) as? [Int] ?? []
        return Set(stored)
    }

    static func save(_ collapsed: Set<Int>, collectionId: Int) {
        if collapsed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(for: collectionId))
        } else {
            UserDefaults.standard.set(Array(collapsed), forKey: key(for: collectionId))
        }
    }
}
