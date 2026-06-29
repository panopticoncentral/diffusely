import Foundation

/// The slice of Civitai networking the Following feature depends on. Declaring
/// it as a protocol lets `FollowingStore` be unit-tested against a mock without
/// touching the network.
protocol FollowingDataSource {
    /// IDs of the users the authenticated account follows. Throws
    /// `URLError(.userAuthenticationRequired)` when no API key is configured.
    func getFollowingUserIds() async throws -> [Int]
    /// Resolves a single id to a profile; nil when deleted/unresolvable.
    func fetchUser(id: Int) async throws -> CivitaiUser?
}

extension CivitaiService: FollowingDataSource {}
