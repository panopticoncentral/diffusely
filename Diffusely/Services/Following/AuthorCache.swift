import Foundation
import SwiftData

/// Read/write access to the local `PersistedAuthor` profile cache, scoped to
/// what the Following feature needs. A protocol so `FollowingStore` can be
/// tested against an in-memory double.
@MainActor
protocol AuthorCaching {
    /// Returns id→user for every id already cached locally (missing ids omitted).
    func cachedUsers(ids: [Int]) -> [Int: CivitaiUser]
    /// Inserts or updates the cached profile for `user`.
    func upsert(_ user: CivitaiUser)
}

/// SwiftData-backed `AuthorCaching`. Mirrors the author fetch/upsert logic in
/// `CollectionPersistenceService`, reused here so resolved follow profiles warm
/// the same cache the rest of the app reads.
@MainActor
final class AuthorCache: AuthorCaching {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func cachedUsers(ids: [Int]) -> [Int: CivitaiUser] {
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<PersistedAuthor>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(
            existing.map { ($0.id, $0.toCivitaiUser()) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func upsert(_ user: CivitaiUser) {
        let userId = user.id
        let descriptor = FetchDescriptor<PersistedAuthor>(
            predicate: #Predicate { $0.id == userId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.username = user.username
            existing.imageURL = user.image
        } else {
            modelContext.insert(PersistedAuthor(from: user))
        }
        try? modelContext.save()
    }
}
