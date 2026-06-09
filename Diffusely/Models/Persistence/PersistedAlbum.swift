import Foundation
import SwiftData

/// Disposable index row for an album. NOT the source of truth — every field is
/// rebuilt from the `album-{uuid}.json` metadata file in the container during
/// reconcile. Intentionally self-contained (no relationships) so it cannot
/// destabilize the existing store, mirroring `PersistedLibraryItem`. Membership
/// is NOT stored here; it lives on each item's sidecar / `albumIDsJoined`.
@Model
final class PersistedAlbum {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
