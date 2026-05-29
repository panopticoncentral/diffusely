import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class ManageCollectionsViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var collections: [CivitaiCollection] = []
    private(set) var membership: Set<Int> = []
    private(set) var pendingFlips: Set<Int> = []
    private(set) var loadState: LoadState = .loading
    private(set) var rowErrors: [Int: String] = [:]

    let target: ManageCollectionsTarget
    private let api: ManageCollectionsAPI
    private let persistence: CollectionPersistenceService

    init(
        target: ManageCollectionsTarget,
        api: ManageCollectionsAPI,
        persistence: CollectionPersistenceService
    ) {
        self.target = target
        self.api = api
        self.persistence = persistence
    }

    /// Fetches the user's collections and current membership in parallel.
    /// Sets `loadState` to `.loaded` on success or `.failed` if either call throws.
    func load() async {
        loadState = .loading
        do {
            async let collectionsTask: [CivitaiCollection] = {
                switch target {
                case .image: return try await api.getUserImageCollections()
                case .post:  return try await api.getUserPostCollections()
                }
            }()
            async let membershipTask: [Int] = api.getUserCollectionItemsByItem(target: target)

            let (cols, member) = try await (collectionsTask, membershipTask)
            self.collections = sortCollections(cols)
            self.membership = Set(member)
            self.loadState = .loaded
        } catch {
            self.loadState = .failed(loadErrorMessage(error))
        }
    }

    /// Flips the row's membership optimistically, writes through to the local
    /// cache, and fires `saveItem`. Reverts both on failure.
    func toggle(_ collection: CivitaiCollection) async {
        let id = collection.id
        guard !pendingFlips.contains(id) else { return }
        pendingFlips.insert(id)
        rowErrors[id] = nil

        let wasIn = membership.contains(id)
        let willBeIn = !wasIn

        // Optimistic state and cache write-through.
        if willBeIn {
            membership.insert(id)
            applyCacheAdd(collectionId: id)
        } else {
            membership.remove(id)
            applyCacheRemove(collectionId: id)
        }

        do {
            try await api.saveItem(
                target: target,
                adding: willBeIn ? [id] : [],
                removing: willBeIn ? [] : [id]
            )
            postMembershipChanged(collectionId: id)
        } catch {
            // Revert state and cache.
            if willBeIn {
                membership.remove(id)
                applyCacheRemove(collectionId: id)
            } else {
                membership.insert(id)
                applyCacheAdd(collectionId: id)
            }
            rowErrors[id] = rowErrorMessage(error)
        }
        pendingFlips.remove(id)
    }

    // MARK: - Helpers

    private func applyCacheAdd(collectionId: Int) {
        switch target {
        case .image(let image):
            persistence.addImageStub(image, toCollectionId: collectionId)
        case .post(let post):
            persistence.addPostStub(post, toCollectionId: collectionId)
        }
    }

    private func applyCacheRemove(collectionId: Int) {
        switch target {
        case .image(let image):
            persistence.removeImage(imageId: image.id, fromCollectionId: collectionId)
        case .post(let post):
            persistence.removePost(postId: post.id, fromCollectionId: collectionId)
        }
    }

    /// Sorts by cached `listOrder` when a `PersistedCollection` exists, then
    /// alphabetical fallback for un-cached collections (which append at the end).
    private func sortCollections(_ input: [CivitaiCollection]) -> [CivitaiCollection] {
        let withOrder: [(CivitaiCollection, Int?)] = input.map { col in
            let listOrder = persistence.getPersistedCollection(id: col.id)?.listOrder
            return (col, listOrder)
        }
        return withOrder.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true            // cached rows first
            case (nil, _?):    return false
            case (nil, nil):
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
        }.map(\.0)
    }

    private func loadErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return "Sign in to manage collections"
        }
        return "Couldn't load collections"
    }

    private func rowErrorMessage(_ error: Error) -> String {
        "Couldn't update. Tap to retry."
    }

    /// Called after `CreateCollectionView` returns a freshly-created collection.
    /// Inserts it into the local cache and the visible list, then fires
    /// `saveItem` to add the current item to it. On failure the collection
    /// stays in the list but does not appear in `membership`.
    func addNewCollection(_ newCollection: CivitaiCollection) async {
        _ = persistence.getOrCreateCollection(from: newCollection)

        // Insert at the top of the list so the user sees their action's result.
        if !collections.contains(where: { $0.id == newCollection.id }) {
            collections.insert(newCollection, at: 0)
        }
        membership.insert(newCollection.id)
        applyCacheAdd(collectionId: newCollection.id)
        pendingFlips.insert(newCollection.id)
        rowErrors[newCollection.id] = nil

        do {
            try await api.saveItem(
                target: target,
                adding: [newCollection.id],
                removing: []
            )
            postMembershipChanged(collectionId: newCollection.id)
        } catch {
            membership.remove(newCollection.id)
            applyCacheRemove(collectionId: newCollection.id)
            rowErrors[newCollection.id] = rowErrorMessage(error)
        }
        pendingFlips.remove(newCollection.id)
    }

    /// Posted after a successful add or remove, so any open
    /// `CollectionDetailView` for the affected collection can refresh its grid.
    /// userInfo: `["collectionId": Int, "itemId": Int]`.
    private func postMembershipChanged(collectionId: Int) {
        NotificationCenter.default.post(
            name: .collectionMembershipChanged,
            object: nil,
            userInfo: ["collectionId": collectionId, "itemId": target.itemId]
        )
    }
}

extension Notification.Name {
    /// Posted by `ManageCollectionsViewModel` after a successful add or
    /// remove. Receivers: `CollectionDetailView` reloads its grid.
    static let collectionMembershipChanged = Notification.Name("CollectionMembershipChanged")
}
