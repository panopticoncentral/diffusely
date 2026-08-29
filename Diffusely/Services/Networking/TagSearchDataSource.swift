import Foundation

/// The slice of Civitai networking the Add Tag sheet depends on. A protocol so
/// the sheet can be exercised without the network, mirroring
/// `FollowingDataSource`.
protocol TagSearchDataSource {
    /// Tags matching `query`, best-match first. Returns `[]` on any error or
    /// for a blank query; tag search is non-critical UI and the caller shows
    /// "no results" rather than an alert.
    func searchTags(query: String) async -> [CivitaiTag]
}

extension CivitaiService: TagSearchDataSource {}
