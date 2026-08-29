import Testing
import Foundation
@testable import Diffusely

@MainActor struct FollowedTagsStoreTests {
    /// A throwaway `UserDefaults` suite so tests never touch the real domain
    /// and can't leak state into each other.
    private func withScratchDefaults(
        _ body: (UserDefaults) async throws -> Void
    ) async rethrows {
        let name = "FollowedTagsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    @Test func startsEmpty() async {
        await withScratchDefaults { defaults in
            #expect(FollowedTagsStore(defaults: defaults).tags.isEmpty)
        }
    }

    @Test func followAddsTheTag() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 7, name: "cyberpunk"))
            #expect(store.tags == [FollowedTag(id: 7, name: "cyberpunk")])
        }
    }

    @Test func followedTagsSurviveANewStoreOverTheSameDefaults() async {
        await withScratchDefaults { defaults in
            FollowedTagsStore(defaults: defaults).follow(FollowedTag(id: 7, name: "cyberpunk"))
            #expect(FollowedTagsStore(defaults: defaults).tags.map(\.id) == [7])
        }
    }

    @Test func sortsAlphabeticallyCaseInsensitive() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 1, name: "Zebra"))
            store.follow(FollowedTag(id: 2, name: "anime"))
            store.follow(FollowedTag(id: 3, name: "Portrait"))
            #expect(store.tags.map(\.name) == ["anime", "Portrait", "Zebra"])
        }
    }

    @Test func tagsWithTheSameNameAreOrderedById() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 9, name: "dog"))
            store.follow(FollowedTag(id: 4, name: "dog"))
            #expect(store.tags.map(\.id) == [4, 9])
        }
    }

    @Test func followingTheSameIdTwiceDoesNotDuplicateIt() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 7, name: "cyberpunk"))
            store.follow(FollowedTag(id: 7, name: "cyberpunk"))
            #expect(store.tags.count == 1)
        }
    }

    /// Re-following an id refreshes its stored name, so a tag renamed on the
    /// server stops showing the stale label once it's seen again.
    @Test func followingAnExistingIdUpdatesItsName() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 7, name: "old name"))
            store.follow(FollowedTag(id: 7, name: "new name"))
            #expect(store.tags == [FollowedTag(id: 7, name: "new name")])
        }
    }

    @Test func unfollowRemovesOnlyThatTag() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 1, name: "anime"))
            store.follow(FollowedTag(id: 2, name: "portrait"))
            store.unfollow(id: 1)
            #expect(store.tags.map(\.id) == [2])
        }
    }

    @Test func unfollowIsPersisted() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 1, name: "anime"))
            store.unfollow(id: 1)
            #expect(FollowedTagsStore(defaults: defaults).tags.isEmpty)
        }
    }

    @Test func unfollowingAnUnknownIdIsANoOp() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 1, name: "anime"))
            store.unfollow(id: 999)
            #expect(store.tags.map(\.id) == [1])
        }
    }

    @Test func isFollowingReflectsMembership() async {
        await withScratchDefaults { defaults in
            let store = FollowedTagsStore(defaults: defaults)
            store.follow(FollowedTag(id: 1, name: "anime"))
            #expect(store.isFollowing(id: 1))
            #expect(!store.isFollowing(id: 2))
        }
    }

    /// Corrupt or foreign data under the key must degrade to "no follows"
    /// rather than trapping at launch.
    @Test func garbageStoredUnderTheKeyDecodesAsEmpty() async {
        await withScratchDefaults { defaults in
            defaults.set("not json", forKey: FollowedTagsStore.storageKey)
            #expect(FollowedTagsStore(defaults: defaults).tags.isEmpty)
        }
    }
}
