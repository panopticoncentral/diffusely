// Diffusely/Models/ManageCollectionsTarget.swift
import Foundation

/// Identifies the item whose collection membership is being managed.
/// Carries the full `CivitaiImage` / `CivitaiPost` (not just an id) because the
/// optimistic cache write-through needs to materialize a `Persisted*` row.
enum ManageCollectionsTarget: Hashable {
    case image(CivitaiImage)
    case post(CivitaiPost)

    /// "image" / "post" — used in user-facing copy.
    var displayName: String {
        switch self {
        case .image: return "image"
        case .post: return "post"
        }
    }

    /// The numeric id of the underlying item.
    var itemId: Int {
        switch self {
        case .image(let image): return image.id
        case .post(let post): return post.id
        }
    }

    /// Matches Civitai's `CollectionType` enum: "Image" or "Post".
    /// Used to filter the user's collections shown in the sheet.
    var collectionType: String {
        switch self {
        case .image: return "Image"
        case .post: return "Post"
        }
    }
}
