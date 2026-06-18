import Foundation
import SwiftData

/// Read-side helper for `LibraryView`. Lives on the main actor because it
/// returns `PersistedLibraryItem` rows owned by the main `ModelContext` and
/// the view consumes them directly. Writes still go through
/// `LibraryIndexService`; this type never mutates.
@MainActor
final class LibrarySortService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Result types

    /// Either a flat ordered list (date sorts) or grouped sections
    /// (author / checkpoint sorts). Mirrors
    /// `CollectionPersistenceService.SortedCollectionContent`.
    enum LibrarySortedContent: Equatable {
        case flat([PersistedLibraryItem])
        case grouped([LibraryGroup])

        var isEmpty: Bool {
            switch self {
            case .flat(let items):    return items.isEmpty
            case .grouped(let groups): return groups.isEmpty
            }
        }
    }

    struct LibraryGroup: Identifiable, Equatable {
        enum Kind: Equatable {
            case author(username: String, avatarURL: String?)
            case checkpoint(name: String)
            case bucket(Bucket)
        }
        enum Bucket: Equatable {
            case videos          // checkpoint sort: items with no checkpoint and type == video
            case other           // checkpoint sort: items with no checkpoint and type == image
            case unknownAuthor   // author sort: items with no authorUsername
        }
        let id: String
        let kind: Kind
        let items: [PersistedLibraryItem]
    }

    /// Everything `LibraryView.reloadContent()` needs, derived from a SINGLE
    /// items fetch (plus one albums fetch). Previously the view called
    /// `sortedLibraryContent` + `albumSummaries` + `notInAnyAlbumCount`
    /// separately, each doing its own full-table fetch on the main thread —
    /// three scans of every row per reload, and reloads fire on every album /
    /// item-count change. Bundling collapses that to one scan.
    struct LibraryContent: Equatable {
        let content: LibrarySortedContent
        let albumSummaries: [AlbumSummary]
        let notInAnyAlbumCount: Int
    }

    // MARK: - Public API

    func libraryContent(sort: LibrarySort, filter: AlbumFilter) -> LibraryContent {
        let albums = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        let known = Set(albums.map { $0.id.uuidString })
        let filtered = applyAlbumFilter(all, filter, knownAlbumIDs: known)
        return LibraryContent(
            content: sortContent(filtered, sort: sort),
            albumSummaries: albumSummaries(items: all, albums: albums),
            notInAnyAlbumCount: notInAnyAlbumCount(items: all, knownAlbumIDs: known)
        )
    }

    func sortedLibraryContent(sort: LibrarySort) -> LibrarySortedContent {
        sortedLibraryContent(sort: sort, filter: .all)
    }

    func sortedLibraryContent(sort: LibrarySort, filter: AlbumFilter) -> LibrarySortedContent {
        sortContent(fetchAll(filter: filter), sort: sort)
    }

    private func sortContent(_ items: [PersistedLibraryItem], sort: LibrarySort) -> LibrarySortedContent {
        switch sort {
        case .dateNewest, .dateOldest:
            return .flat(sortByDate(items, ascending: sort.ascending))
        case .authorAscending, .authorDescending:
            return .grouped(groupByAuthor(items, ascending: sort.ascending))
        case .checkpointAscending, .checkpointDescending:
            return .grouped(groupByCheckpoint(items, ascending: sort.ascending))
        }
    }

    /// Cheap, index-only count of items the publish-date backfill would act on:
    /// no `publishedAt` and no recorded attempt. Items the API already confirmed
    /// have no date (marker set) are excluded, so a fully-drained library
    /// returns 0 and `LibraryView` skips the sidecar directory walk entirely.
    func countItemsNeedingDateBackfill() -> Int {
        let descriptor = FetchDescriptor<PersistedLibraryItem>(
            predicate: #Predicate { $0.needsDateBackfill }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Internals

    private func fetchAll(filter: AlbumFilter = .all) -> [PersistedLibraryItem] {
        let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        // Only `.notInAnyAlbum` needs the album set, so don't fetch it otherwise.
        let known: Set<String>
        if case .notInAnyAlbum = filter { known = knownAlbumIDStrings() } else { known = [] }
        return applyAlbumFilter(all, filter, knownAlbumIDs: known)
    }

    /// Applies an album filter to an already-fetched item array. Pure (no fetch)
    /// so callers that already hold the items + known album IDs reuse it.
    private func applyAlbumFilter(
        _ all: [PersistedLibraryItem],
        _ filter: AlbumFilter,
        knownAlbumIDs: Set<String>
    ) -> [PersistedLibraryItem] {
        switch filter {
        case .all:
            return all
        case .album(let id):
            let key = id.uuidString
            return all.filter { $0.belongs(toAlbum: key) }
        case .notInAnyAlbum:
            return all.filter { item in item.albumIDs.allSatisfy { !knownAlbumIDs.contains($0) } }
        }
    }

    private func knownAlbumIDStrings() -> Set<String> {
        let albums = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        return Set(albums.map { $0.id.uuidString })
    }

    /// Newest-first when `ascending == false`. Items with `publishedAt == nil`
    /// sink to the tail in both directions; ties (including the nil bucket)
    /// break by `itemID` descending for stability.
    private func sortByDate(_ items: [PersistedLibraryItem], ascending: Bool) -> [PersistedLibraryItem] {
        items.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (a?, b?):
                if a == b { return lhs.itemID > rhs.itemID }
                return ascending ? a < b : a > b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.itemID > rhs.itemID
            }
        }
    }

    /// Same nil-sink + id-descending tie-break used for flat date sorts, but
    /// always newest-first (used inside groups).
    private func newestFirst(_ items: [PersistedLibraryItem]) -> [PersistedLibraryItem] {
        sortByDate(items, ascending: false)
    }

    private func groupByAuthor(
        _ items: [PersistedLibraryItem],
        ascending: Bool
    ) -> [LibraryGroup] {
        // Bucket by lowercased username; items with no username go to a single
        // "Unknown" group placed at the tail regardless of direction.
        var named: [String: (display: String, avatar: String?, items: [PersistedLibraryItem])] = [:]
        var unknown: [PersistedLibraryItem] = []

        for item in items {
            guard let username = item.authorUsername, !username.isEmpty else {
                unknown.append(item)
                continue
            }
            let key = username.lowercased()
            if var entry = named[key] {
                entry.items.append(item)
                if entry.avatar == nil { entry.avatar = item.authorAvatarURL }
                named[key] = entry
            } else {
                named[key] = (display: username, avatar: item.authorAvatarURL, items: [item])
            }
        }

        var groups: [LibraryGroup] = named
            .map { key, entry in
                LibraryGroup(
                    id: "author:\(key)",
                    kind: .author(username: entry.display, avatarURL: entry.avatar),
                    items: newestFirst(entry.items)
                )
            }
            .sorted { lhs, rhs in
                let l = displayName(lhs).lowercased()
                let r = displayName(rhs).lowercased()
                return ascending ? l < r : l > r
            }

        if !unknown.isEmpty {
            groups.append(LibraryGroup(
                id: "author:__unknown__",
                kind: .bucket(.unknownAuthor),
                items: newestFirst(unknown)
            ))
        }
        return groups
    }

    private func groupByCheckpoint(
        _ items: [PersistedLibraryItem],
        ascending: Bool
    ) -> [LibraryGroup] {
        var named: [String: [PersistedLibraryItem]] = [:]
        var videos: [PersistedLibraryItem] = []
        var other: [PersistedLibraryItem] = []

        for item in items {
            if let name = item.checkpointName, !name.isEmpty {
                named[name, default: []].append(item)
            } else if item.isVideo {
                videos.append(item)
            } else {
                other.append(item)
            }
        }

        var groups: [LibraryGroup] = named
            .map { name, list in
                LibraryGroup(
                    id: "checkpoint:\(name)",
                    kind: .checkpoint(name: name),
                    items: newestFirst(list)
                )
            }
            .sorted { lhs, rhs in
                let l = displayName(lhs).lowercased()
                let r = displayName(rhs).lowercased()
                return ascending ? l < r : l > r
            }

        if !videos.isEmpty {
            groups.append(LibraryGroup(
                id: "bucket:videos",
                kind: .bucket(.videos),
                items: newestFirst(videos)
            ))
        }
        if !other.isEmpty {
            groups.append(LibraryGroup(
                id: "bucket:other",
                kind: .bucket(.other),
                items: newestFirst(other)
            ))
        }
        return groups
    }

    private func displayName(_ group: LibraryGroup) -> String {
        switch group.kind {
        case .author(let username, _): return username
        case .checkpoint(let name):     return name
        case .bucket(.videos):          return "Videos"
        case .bucket(.other):           return "Other"
        case .bucket(.unknownAuthor):   return "Unknown"
        }
    }

    // MARK: - Album summaries

    struct AlbumSummary: Identifiable, Equatable {
        let id: UUID
        let name: String
        let count: Int
        let coverItem: PersistedLibraryItem?

        static func == (l: AlbumSummary, r: AlbumSummary) -> Bool {
            l.id == r.id && l.name == r.name && l.count == r.count
                && l.coverItem?.itemID == r.coverItem?.itemID
        }
    }

    /// One row per album for the Albums grid: name, member count, and the most
    /// recent member as the cover. Albums with no members get a nil cover.
    /// Groups membership in ONE pass over the items (each item's joined-ids
    /// string split once) — the per-album `belongs(toAlbum:)` filter was
    /// O(albums × items) string splits, which stalled the main thread on every
    /// reload at thousands of items × dozens of albums.
    func albumSummaries() -> [AlbumSummary] {
        let albums = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        return albumSummaries(items: all, albums: albums)
    }

    private func albumSummaries(items: [PersistedLibraryItem], albums: [PersistedAlbum]) -> [AlbumSummary] {
        var membersByAlbum: [String: [PersistedLibraryItem]] = [:]
        for item in items {
            for albumID in item.albumIDs {
                membersByAlbum[albumID, default: []].append(item)
            }
        }
        return albums
            .map { album in
                let members = newestFirst(membersByAlbum[album.id.uuidString] ?? [])
                return AlbumSummary(id: album.id, name: album.name,
                                    count: members.count, coverItem: members.first)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Count of items in zero existing albums — the "Not in any Album" badge.
    func notInAnyAlbumCount() -> Int {
        fetchAll(filter: .notInAnyAlbum).count
    }

    private func notInAnyAlbumCount(items: [PersistedLibraryItem], knownAlbumIDs: Set<String>) -> Int {
        items.filter { item in item.albumIDs.allSatisfy { !knownAlbumIDs.contains($0) } }.count
    }

    /// For the given selection, how many of those items belong to each album.
    /// Albums with zero members of the selection are omitted. Drives the
    /// tri-state checkmarks in `ManageAlbumsSheet`.
    func albumMembershipCounts(for itemIDs: [Int]) -> [UUID: Int] {
        guard !itemIDs.isEmpty else { return [:] }
        let idSet = Set(itemIDs)
        let albums = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        let selected = all.filter { idSet.contains($0.itemID) }
        var counts: [UUID: Int] = [:]
        for album in albums {
            let key = album.id.uuidString
            let count = selected.filter { $0.belongs(toAlbum: key) }.count
            if count > 0 { counts[album.id] = count }
        }
        return counts
    }
}
