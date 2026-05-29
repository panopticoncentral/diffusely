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

    // MARK: - Public API

    func sortedLibraryContent(sort: LibrarySort) -> LibrarySortedContent {
        let all = fetchAll()
        switch sort {
        case .dateNewest, .dateOldest:
            return .flat(sortByDate(all, ascending: sort.ascending))
        case .authorAscending, .authorDescending:
            return .grouped(groupByAuthor(all, ascending: sort.ascending))
        case .checkpointAscending, .checkpointDescending:
            return .grouped(groupByCheckpoint(all, ascending: sort.ascending))
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

    private func fetchAll() -> [PersistedLibraryItem] {
        (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
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
}
