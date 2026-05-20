import Foundation

/// Sort options for the personal library. Flat enum (like `CollectionSort` and
/// `FeedSort`) so it drops into the menu/checkmark pattern and persists as a
/// `String` rawValue if we ever want to.
enum LibrarySort: String, CaseIterable, Identifiable, Equatable {
    case dateNewest           = "Date (Newest)"
    case dateOldest           = "Date (Oldest)"
    case authorAscending      = "Author (A–Z)"
    case authorDescending     = "Author (Z–A)"
    case checkpointAscending  = "Checkpoint (A–Z)"
    case checkpointDescending = "Checkpoint (Z–A)"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// True when this sort produces author-grouped sections.
    var isAuthorGrouped: Bool {
        self == .authorAscending || self == .authorDescending
    }

    /// True when this sort produces checkpoint-grouped sections.
    var isCheckpointGrouped: Bool {
        self == .checkpointAscending || self == .checkpointDescending
    }

    /// True for any grouped sort (author or checkpoint).
    var isGrouped: Bool { isAuthorGrouped || isCheckpointGrouped }

    /// For grouped sorts: section order. For date sorts: items oldest-first
    /// when true, newest-first when false.
    var ascending: Bool {
        switch self {
        case .dateOldest, .authorAscending, .checkpointAscending:   return true
        case .dateNewest, .authorDescending, .checkpointDescending: return false
        }
    }

    /// SF Symbol shown next to each menu item (replaced by a checkmark when
    /// selected). Mirrors `CollectionSort.icon`.
    var icon: String {
        switch self {
        case .dateNewest:           return "clock.fill"
        case .dateOldest:           return "calendar"
        case .authorAscending:      return "arrow.up"
        case .authorDescending:     return "arrow.down"
        case .checkpointAscending:  return "arrow.up"
        case .checkpointDescending: return "arrow.down"
        }
    }
}
