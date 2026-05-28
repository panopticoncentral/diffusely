import Foundation

/// Sort options for a collection's contents. A flat enum (like `FeedSort`)
/// so it drops straight into the menu/checkmark pattern and persists as a
/// `String` rawValue.
enum CollectionSort: String, CaseIterable, Identifiable, Equatable {
    case authorAscending  = "Author (A–Z)"
    case authorDescending = "Author (Z–A)"
    case dateNewest       = "Date (Newest)"
    case dateOldest       = "Date (Oldest)"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Author sorts keep the collapsible author-grouped sections;
    /// date sorts produce a flat chronological grid.
    var isAuthorGrouped: Bool {
        self == .authorAscending || self == .authorDescending
    }

    /// For author-grouped sorts: whether sections go A→Z.
    var authorAscending: Bool {
        self == .authorAscending
    }

    /// For date sorts: whether newest items come first.
    var dateDescending: Bool {
        self == .dateNewest
    }

    var icon: String {
        switch self {
        case .authorAscending:  return "arrow.up"
        case .authorDescending: return "arrow.down"
        case .dateNewest:       return "clock.fill"
        case .dateOldest:       return "calendar"
        }
    }
}
