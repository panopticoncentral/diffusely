import Foundation

/// A tag on an image/video, as returned by Civitai's `tag.getVotableTags`.
/// Civitai treats videos as images, so the same endpoint serves both.
/// The server already curates this list (suppressing noisy auto-tags); we only
/// display the result and filter feeds by `id`.
struct CivitaiVotableTag: Codable, Identifiable, Hashable {
    let id: Int          // drives both the feed filter and the SwiftUI list key
    let name: String     // chip label
    let type: String     // "UserGenerated" | "Label" | "Moderation" | "System"
    let nsfwLevel: Int
    let score: Int
}
