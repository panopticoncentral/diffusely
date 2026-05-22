import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// Regression: an item (post or image) that belongs to several collections on
/// Civitai must remain cached in ALL of them locally. The original schema made
/// `PersistedPost.id` / `PersistedImage.id` / `PersistedPostImage.id` unique with
/// a single to-one `collection` reference, so caching the item for one collection
/// silently stole it from the others (the unique constraint upserted the lone row
/// and reassigned its collection). These tests add the same item to two
/// collections and assert it survives in both.
@Suite @MainActor struct MultiCollectionMembershipTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PersistedCollection.self, PersistedAuthor.self,
                 PersistedImage.self, PersistedPost.self, PersistedPostImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    private func apiCollection(id: Int, type: String) -> CivitaiCollection {
        CivitaiCollection(
            id: id, name: "C\(id)", description: nil, type: type,
            imageCount: 0, image: nil, user: CivitaiUser(id: 500, username: "owner", image: nil)
        )
    }

    private func stubImage(id: Int) -> CivitaiImage {
        CivitaiImage(id: id, url: "u-\(id)", width: 10, height: 10,
                     nsfwLevel: 1, type: "image", postId: 7,
                     user: CivitaiUser(id: 1, username: "a", image: nil), stats: nil)
    }

    private func stubPost(id: Int, imageId: Int) -> CivitaiPost {
        CivitaiPost(
            id: id, nsfwLevel: 1, title: "T", imageCount: 1,
            user: CivitaiUser(id: 1, username: "a", image: nil),
            stats: nil, images: [stubImage(id: imageId)]
        )
    }

    @Test func postStaysInBothCollectionsWhenAddedToEach() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let collA = svc.getOrCreateCollection(from: apiCollection(id: 1, type: "Post"))
        let collB = svc.getOrCreateCollection(from: apiCollection(id: 2, type: "Post"))

        let post = stubPost(id: 7, imageId: 70)
        svc.addPosts([post], to: collA)
        svc.addPosts([post], to: collB)

        #expect(collA.posts.contains { $0.id == 7 })
        #expect(collB.posts.contains { $0.id == 7 })

        // Each collection's copy keeps its own post image (validates that
        // PersistedPostImage.id is no longer globally unique either).
        #expect(collA.posts.first { $0.id == 7 }?.images.count == 1)
        #expect(collB.posts.first { $0.id == 7 }?.images.count == 1)
    }

    @Test func imageStaysInBothCollectionsWhenAddedToEach() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let collA = svc.getOrCreateCollection(from: apiCollection(id: 3, type: "Image"))
        let collB = svc.getOrCreateCollection(from: apiCollection(id: 4, type: "Image"))

        let image = stubImage(id: 8)
        svc.addImages([image], to: collA)
        svc.addImages([image], to: collB)

        #expect(collA.images.contains { $0.id == 8 })
        #expect(collB.images.contains { $0.id == 8 })
    }

    /// Removing an item from one collection must not affect the other.
    @Test func removingFromOneCollectionLeavesTheOther() throws {
        let svc = CollectionPersistenceService(modelContext: try makeContext())
        let collA = svc.getOrCreateCollection(from: apiCollection(id: 5, type: "Image"))
        let collB = svc.getOrCreateCollection(from: apiCollection(id: 6, type: "Image"))

        let image = stubImage(id: 9)
        svc.addImages([image], to: collA)
        svc.addImages([image], to: collB)

        svc.removeImage(imageId: 9, fromCollectionId: collA.id)

        #expect(!collA.images.contains { $0.id == 9 })
        #expect(collB.images.contains { $0.id == 9 })
    }
}
