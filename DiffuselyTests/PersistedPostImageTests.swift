import Testing
import Foundation
import SwiftData
@testable import Diffusely

@Suite @MainActor struct PersistedPostImageTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PersistedCollection.self, PersistedAuthor.self,
                 PersistedImage.self, PersistedPost.self, PersistedPostImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    /// Regression: `toCivitaiImage()` used to hardcode `user: nil`, which silently
    /// stripped the author when a user saved a collection-post image to their
    /// library — every saved item then landed in the "Unknown" author bucket.
    /// The author lives on the parent `PersistedPost`; the back-reference is
    /// already there. Confirm it flows through.
    @Test func toCivitaiImagePropagatesParentPostAuthor() throws {
        let ctx = try makeContext()

        let author = PersistedAuthor(id: 42, username: "alice", imageURL: "https://x/a.png")
        ctx.insert(author)

        let post = PersistedPost(id: 100, nsfwLevel: 1, title: "T", imageCount: 1)
        post.author = author
        ctx.insert(post)

        let image = PersistedPostImage(
            id: 200, url: "uuid-200", width: 1, height: 1,
            nsfwLevel: 1, imageType: "image"
        )
        image.post = post
        ctx.insert(image)

        let reconstructed = image.toCivitaiImage()
        #expect(reconstructed.user?.id == 42)
        #expect(reconstructed.user?.username == "alice")
        #expect(reconstructed.user?.image == "https://x/a.png")
        // Same line of bug: postId was also hardcoded nil. Surface the parent
        // post id so canonical post URLs and post-title lookups work on save.
        #expect(reconstructed.postId == 100)
    }

    @Test func toCivitaiImageLeavesUserNilWhenPostHasNoAuthor() throws {
        let ctx = try makeContext()

        let post = PersistedPost(id: 101, nsfwLevel: 1, title: nil, imageCount: 1)
        ctx.insert(post)

        let image = PersistedPostImage(
            id: 201, url: "uuid-201", width: 1, height: 1,
            nsfwLevel: 1, imageType: "image"
        )
        image.post = post
        ctx.insert(image)

        let reconstructed = image.toCivitaiImage()
        #expect(reconstructed.user == nil)
        #expect(reconstructed.postId == 101)
    }

    @Test func toCivitaiImageLeavesPostIdNilWhenDetached() {
        let image = PersistedPostImage(
            id: 202, url: "uuid-202", width: 1, height: 1,
            nsfwLevel: 1, imageType: "image"
        )
        // image.post is nil — no parent.

        let reconstructed = image.toCivitaiImage()
        #expect(reconstructed.user == nil)
        #expect(reconstructed.postId == nil)
    }
}
