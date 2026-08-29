import Foundation

/// A tag as returned by Civitai's `tag.getAll` (the search/autocomplete
/// endpoint). Distinct from `CivitaiVotableTag`, which is the richer per-image
/// shape from `tag.getVotableTags` — `tag.getAll` items carry no `type`,
/// `score`, or `nsfwLevel` unless explicitly requested, so they can't decode
/// into that type.
struct CivitaiTag: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
}
