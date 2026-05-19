import Foundation
import SwiftData

@MainActor
class CollectionPersistenceService: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Collection Operations

    func getPersistedCollection(id: Int) -> PersistedCollection? {
        let descriptor = FetchDescriptor<PersistedCollection>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func getOrCreateCollection(from apiCollection: CivitaiCollection) -> PersistedCollection {
        if let existing = getPersistedCollection(id: apiCollection.id) {
            // Update name in case it changed
            existing.name = apiCollection.name
            return existing
        }
        let new = PersistedCollection(from: apiCollection)
        modelContext.insert(new)
        try? modelContext.save()
        return new
    }

    // MARK: - Author Operations

    func getOrCreateAuthor(from user: CivitaiUser) -> PersistedAuthor {
        let userId = user.id
        let descriptor = FetchDescriptor<PersistedAuthor>(
            predicate: #Predicate { $0.id == userId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            // Update username/image in case they changed
            existing.username = user.username
            existing.imageURL = user.image
            return existing
        }
        let new = PersistedAuthor(from: user)
        modelContext.insert(new)
        return new
    }

    // MARK: - Image Operations

    func addImages(_ images: [CivitaiImage], to collection: PersistedCollection) {
        let generation = collection.syncGeneration
        for image in images {
            // Check if image already exists in this collection
            let imageId = image.id
            let collectionId = collection.id
            let descriptor = FetchDescriptor<PersistedImage>(
                predicate: #Predicate { $0.id == imageId && $0.collection?.id == collectionId }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                // Update stats if needed
                if let stats = image.stats {
                    existing.likeCount = stats.likeCountAllTime
                    existing.heartCount = stats.heartCountAllTime
                    existing.commentCount = stats.commentCountAllTime
                }
                // Backfill publishedAt for items persisted before date sorting existed
                existing.publishedAt = image.publishedAtDate
                existing.lastSeenGeneration = generation
                continue
            }

            let persisted = PersistedImage(from: image)
            persisted.collection = collection
            persisted.lastSeenGeneration = generation

            if let user = image.user {
                persisted.author = getOrCreateAuthor(from: user)
            }

            modelContext.insert(persisted)
            collection.images.append(persisted)
        }
        try? modelContext.save()
    }

    // MARK: - Post Operations

    func addPosts(_ posts: [CivitaiPost], to collection: PersistedCollection) {
        let generation = collection.syncGeneration
        for post in posts {
            // Check if post already exists in this collection
            let postId = post.id
            let collectionId = collection.id
            let descriptor = FetchDescriptor<PersistedPost>(
                predicate: #Predicate { $0.id == postId && $0.collection?.id == collectionId }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                // Update stats if needed
                if let stats = post.stats {
                    existing.likeCount = stats.likeCount
                    existing.heartCount = stats.heartCount
                    existing.commentCount = stats.commentCount
                }
                // Backfill publishedAt for items persisted before date sorting existed
                existing.publishedAt = post.publishedAtDate
                existing.lastSeenGeneration = generation
                continue
            }

            let persisted = PersistedPost(from: post)
            persisted.collection = collection
            persisted.lastSeenGeneration = generation
            persisted.author = getOrCreateAuthor(from: post.user)

            // Add post images
            for image in post.safeImages {
                let postImage = PersistedPostImage(from: image)
                postImage.post = persisted
                modelContext.insert(postImage)
                persisted.images.append(postImage)
            }

            modelContext.insert(persisted)
            collection.posts.append(persisted)
        }
        try? modelContext.save()
    }

    // MARK: - Removal

    func removeImage(imageId: Int, fromCollectionId collectionId: Int) {
        let descriptor = FetchDescriptor<PersistedImage>(
            predicate: #Predicate { $0.id == imageId && $0.collection?.id == collectionId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    func removePost(postId: Int, fromCollectionId collectionId: Int) {
        let descriptor = FetchDescriptor<PersistedPost>(
            predicate: #Predicate { $0.id == postId && $0.collection?.id == collectionId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    // MARK: - Grouped Queries

    struct AuthorGroup: Identifiable {
        let author: CivitaiUser
        var images: [CivitaiImage]
        var posts: [CivitaiPost]

        var id: Int { author.id }

        var itemCount: Int {
            images.count + posts.count
        }
    }

    /// Result of a sort: either author-grouped sections or a flat
    /// chronologically-ordered list of items.
    enum SortedCollectionContent {
        case grouped([AuthorGroup])
        case flatImages([CivitaiImage])
        case flatPosts([CivitaiPost])

        var isEmpty: Bool {
            switch self {
            case .grouped(let groups): return groups.isEmpty
            case .flatImages(let images): return images.isEmpty
            case .flatPosts(let posts): return posts.isEmpty
            }
        }
    }

    /// Single entry point honoring the selected sort.
    func getSortedContent(
        for collectionId: Int,
        type: String,
        sort: CollectionSort
    ) -> SortedCollectionContent {
        if sort.isAuthorGrouped {
            let groups = type == "Post"
                ? getPostsGroupedByAuthor(for: collectionId, ascending: sort.authorAscending)
                : getImagesGroupedByAuthor(for: collectionId, ascending: sort.authorAscending)
            return .grouped(groups)
        } else {
            if type == "Post" {
                return .flatPosts(getPostsSortedByDate(for: collectionId, descending: sort.dateDescending))
            } else {
                return .flatImages(getImagesSortedByDate(for: collectionId, descending: sort.dateDescending))
            }
        }
    }

    /// Sorts so dated items come first (asc/desc as requested) and
    /// items missing a publish date sort last in a stable `id` order.
    private static func compareByDate(
        _ aDate: Date?, _ aId: Int,
        _ bDate: Date?, _ bId: Int,
        descending: Bool
    ) -> Bool {
        switch (aDate, bDate) {
        case let (x?, y?): return descending ? x > y : x < y
        case (nil, _?):    return false
        case (_?, nil):    return true
        case (nil, nil):   return aId > bId
        }
    }

    func getImagesSortedByDate(for collectionId: Int, descending: Bool) -> [CivitaiImage] {
        guard let collection = getPersistedCollection(id: collectionId) else { return [] }
        return collection.images
            .map { (date: $0.publishedAt, id: $0.id, image: $0.toCivitaiImage()) }
            .sorted { Self.compareByDate($0.date, $0.id, $1.date, $1.id, descending: descending) }
            .map { $0.image }
    }

    func getPostsSortedByDate(for collectionId: Int, descending: Bool) -> [CivitaiPost] {
        guard let collection = getPersistedCollection(id: collectionId) else { return [] }
        return collection.posts
            .map { (date: $0.publishedAt, id: $0.id, post: $0.toCivitaiPost()) }
            .sorted { Self.compareByDate($0.date, $0.id, $1.date, $1.id, descending: descending) }
            .map { $0.post }
    }

    /// Number of cached items lacking a publish date. Non-zero means the
    /// collection was cached before date sorting existed and needs a
    /// one-time backfill sync before date sorting can work.
    func countItemsMissingPublishedDate(for collectionId: Int, type: String) -> Int {
        guard let collection = getPersistedCollection(id: collectionId) else { return 0 }
        if type == "Post" {
            return collection.posts.filter { $0.publishedAt == nil }.count
        } else {
            return collection.images.filter { $0.publishedAt == nil }.count
        }
    }

    func getImagesGroupedByAuthor(for collectionId: Int, ascending: Bool = true) -> [AuthorGroup] {
        guard let collection = getPersistedCollection(id: collectionId) else { return [] }

        var groupedByAuthorId: [Int: (author: PersistedAuthor, images: [PersistedImage])] = [:]

        for image in collection.images {
            let authorId = image.author?.id ?? 0
            if groupedByAuthorId[authorId] == nil {
                let author = image.author ?? PersistedAuthor(id: 0, username: "Unknown Artist", imageURL: nil)
                groupedByAuthorId[authorId] = (author: author, images: [])
            }
            groupedByAuthorId[authorId]?.images.append(image)
        }

        // Convert to AuthorGroup and sort alphabetically by username
        return groupedByAuthorId.values
            .map { (author, images) in
                AuthorGroup(
                    author: author.toCivitaiUser(),
                    images: images.map { $0.toCivitaiImage() },
                    posts: []
                )
            }
            .sorted { lhs, rhs in
                let l = (lhs.author.username ?? "zzz").lowercased()
                let r = (rhs.author.username ?? "zzz").lowercased()
                return ascending ? l < r : l > r
            }
    }

    func getPostsGroupedByAuthor(for collectionId: Int, ascending: Bool = true) -> [AuthorGroup] {
        guard let collection = getPersistedCollection(id: collectionId) else { return [] }

        var groupedByAuthorId: [Int: (author: PersistedAuthor, posts: [PersistedPost])] = [:]

        for post in collection.posts {
            let authorId = post.author?.id ?? 0
            if groupedByAuthorId[authorId] == nil {
                let author = post.author ?? PersistedAuthor(id: 0, username: "Unknown Artist", imageURL: nil)
                groupedByAuthorId[authorId] = (author: author, posts: [])
            }
            groupedByAuthorId[authorId]?.posts.append(post)
        }

        // Convert to AuthorGroup and sort alphabetically by username
        return groupedByAuthorId.values
            .map { (author, posts) in
                AuthorGroup(
                    author: author.toCivitaiUser(),
                    images: [],
                    posts: posts.map { $0.toCivitaiPost() }
                )
            }
            .sorted { lhs, rhs in
                let l = (lhs.author.username ?? "zzz").lowercased()
                let r = (rhs.author.username ?? "zzz").lowercased()
                return ascending ? l < r : l > r
            }
    }

    // MARK: - Sync State

    func updateSyncCursor(for collectionId: Int, cursor: String?) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        collection.syncCursor = cursor
        try? modelContext.save()
    }

    func markSyncStarted(for collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        collection.lastSyncStarted = Date()
        collection.isSyncing = true
        try? modelContext.save()
    }

    /// Bumps the collection's sync generation so the next add/update cycle stamps items with a new value.
    /// Call this at the start of a fresh full pass (i.e. when syncCursor is nil), not on resume.
    func beginFreshSyncPass(for collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        collection.syncGeneration &+= 1
        try? modelContext.save()
    }

    func markSyncCompleted(for collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        sweepStaleItems(in: collection)
        collection.lastSyncCompleted = Date()
        collection.isSyncing = false
        collection.syncCursor = nil
        try? modelContext.save()
    }

    /// Deletes items in the collection that were not observed in the current sync generation.
    /// Safe to call only after a complete pass — partial passes will not have stamped later items yet.
    private func sweepStaleItems(in collection: PersistedCollection) {
        let generation = collection.syncGeneration
        var deletedImages = 0
        var deletedPosts = 0

        if collection.collectionType == "Image" {
            for image in collection.images where image.lastSeenGeneration < generation {
                modelContext.delete(image)
                deletedImages += 1
            }
        } else {
            for post in collection.posts where post.lastSeenGeneration < generation {
                modelContext.delete(post)
                deletedPosts += 1
            }
        }

        if deletedImages > 0 || deletedPosts > 0 {
            print("[Sync] Swept stale items for collection \(collection.id): \(deletedImages) images, \(deletedPosts) posts (generation \(generation))")
        }
    }

    /// Returns true if sync is needed (never synced, or last sync was more than `staleAfter` seconds ago)
    func needsSync(for collectionId: Int, staleAfter: TimeInterval = 300) -> Bool {
        guard let collection = getPersistedCollection(id: collectionId) else {
            return true  // No persisted collection, definitely need to sync
        }

        // If currently syncing, don't start another
        if collection.isSyncing {
            return false
        }

        // If never completed a sync, need to sync
        guard let lastSync = collection.lastSyncCompleted else {
            return true
        }

        // Check if sync is stale (default: 5 minutes)
        return Date().timeIntervalSince(lastSync) > staleAfter
    }

    /// Returns the last sync time for display purposes
    func lastSyncTime(for collectionId: Int) -> Date? {
        getPersistedCollection(id: collectionId)?.lastSyncCompleted
    }
}
