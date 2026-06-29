import Foundation
import SwiftUI

/// One creator in the Following list. `failed` rows are placeholders for IDs we
/// couldn't resolve this pass; they collate last and retry on refresh.
struct FollowedUserRow: Identifiable, Equatable {
    let id: Int
    let username: String?
    let imageURL: String?
    let failed: Bool

    init(user: CivitaiUser, failed: Bool = false) {
        self.id = user.id
        self.username = user.username
        self.imageURL = user.image
        self.failed = failed
    }

    init(id: Int, username: String?, imageURL: String?, failed: Bool) {
        self.id = id
        self.username = username
        self.imageURL = imageURL
        self.failed = failed
    }

    var civitaiUser: CivitaiUser { CivitaiUser(id: id, username: username, image: imageURL) }

    /// Name used for sorting; nil (collates last) for failed or unnamed rows.
    var sortName: String? {
        guard !failed, let username, !username.isEmpty else { return nil }
        return username
    }

    /// Alphabetical (case-insensitive); unnamed/failed rows last, then by id.
    static func sorted(_ rows: [FollowedUserRow]) -> [FollowedUserRow] {
        rows.sorted { a, b in
            switch (a.sortName, b.sortName) {
            case let (x?, y?):
                let order = x.localizedCaseInsensitiveCompare(y)
                if order == .orderedSame { return a.id < b.id }
                return order == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.id < b.id
            }
        }
    }
}

enum FollowingViewState: Equatable {
    case loading
    case noAPIKey
    case empty
    case error(String)
    case loaded
}

@MainActor
final class FollowingStore: ObservableObject {
    @Published private(set) var rows: [FollowedUserRow] = []
    @Published private(set) var resolvingCount = 0
    @Published private(set) var state: FollowingViewState = .loading

    private var dataSource: FollowingDataSource?
    private var cache: AuthorCaching?
    private var generation = 0

    /// Maximum number of `getById` calls in flight at once.
    private let maxConcurrent = 6

    /// Wires up dependencies once (idempotent). Call before `load()`.
    func configure(dataSource: FollowingDataSource, cache: AuthorCaching) {
        guard self.dataSource == nil else { return }
        self.dataSource = dataSource
        self.cache = cache
    }

    func load() async { await runLoad(isRefresh: false) }
    func refresh() async { await runLoad(isRefresh: true) }

    private func runLoad(isRefresh: Bool) async {
        guard let dataSource, let cache else { return }
        generation &+= 1
        let gen = generation

        resolvingCount = 0
        if !isRefresh {
            state = .loading
            rows = []
        }

        let ids: [Int]
        do {
            ids = try await dataSource.getFollowingUserIds()
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            state = .noAPIKey
            rows = []
            resolvingCount = 0
            return
        } catch {
            if rows.isEmpty { state = .error(error.localizedDescription) }
            resolvingCount = 0
            return
        }
        guard gen == generation else { return }

        var seen = Set<Int>()
        let uniqueIds = ids.filter { seen.insert($0).inserted }

        if uniqueIds.isEmpty {
            rows = []
            resolvingCount = 0
            state = .empty
            return
        }

        // Cache-first: show what we already know, sorted, immediately.
        let cached = cache.cachedUsers(ids: uniqueIds)
        rows = FollowedUserRow.sorted(cached.values.map { FollowedUserRow(user: $0) })
        state = .loaded

        let gaps = uniqueIds.filter { cached[$0] == nil }
        resolvingCount = gaps.count
        await resolveGaps(gaps, generation: gen)
    }

    private func resolveGaps(_ ids: [Int], generation gen: Int) async {
        for chunk in chunked(ids, into: maxConcurrent) {
            if gen != generation { return }
            let tasks = chunk.map { id in
                Task { @MainActor in await self.resolveOne(id: id, generation: gen) }
            }
            for task in tasks {
                await task.value
                if gen == generation { resolvingCount = max(0, resolvingCount - 1) }
            }
        }
    }

    private func resolveOne(id: Int, generation gen: Int) async {
        guard let dataSource, let cache else { return }
        let resolved: CivitaiUser?
        do {
            resolved = try await dataSource.fetchUser(id: id)
        } catch {
            guard gen == generation else { return }
            applyFailure(id: id)
            return
        }
        guard gen == generation else { return }
        if let user = resolved {
            cache.upsert(user)
            apply(user: user)
        }
    }

    private func apply(user: CivitaiUser) {
        var updated = rows.filter { $0.id != user.id }
        updated.append(FollowedUserRow(user: user))
        rows = FollowedUserRow.sorted(updated)
    }

    private func applyFailure(id: Int) {
        guard !rows.contains(where: { $0.id == id }) else { return }
        var updated = rows
        updated.append(FollowedUserRow(id: id, username: nil, imageURL: nil, failed: true))
        rows = FollowedUserRow.sorted(updated)
    }

    private func chunked<T>(_ array: [T], into size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0 ..< Swift.min($0 + size, array.count)])
        }
    }
}
