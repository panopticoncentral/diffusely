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
                continue
            }

            let persisted = PersistedImage(from: image)
            persisted.collection = collection

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
                continue
            }

            let persisted = PersistedPost(from: post)
            persisted.collection = collection
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

    func getImagesGroupedByAuthor(for collectionId: Int) -> [AuthorGroup] {
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
            .sorted { ($0.author.username ?? "zzz").lowercased() < ($1.author.username ?? "zzz").lowercased() }
    }

    func getPostsGroupedByAuthor(for collectionId: Int) -> [AuthorGroup] {
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
            .sorted { ($0.author.username ?? "zzz").lowercased() < ($1.author.username ?? "zzz").lowercased() }
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

    func markSyncCompleted(for collectionId: Int) {
        guard let collection = getPersistedCollection(id: collectionId) else { return }
        collection.lastSyncCompleted = Date()
        collection.isSyncing = false
        collection.syncCursor = nil
        try? modelContext.save()
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
