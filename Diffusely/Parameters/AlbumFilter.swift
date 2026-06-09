import Foundation

/// Scopes the Library read side. `.all` is the whole library; `.album` is one
/// album's members; `.notInAnyAlbum` is the complement (items in zero *existing*
/// albums — dangling references to deleted albums count as "not in any album").
enum AlbumFilter: Equatable, Hashable {
    case all
    case album(UUID)
    case notInAnyAlbum
}
