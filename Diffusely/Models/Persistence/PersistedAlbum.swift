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
    var userDescription: String?
    var aiProfileText: String?
    var aiProfileBuiltAt: Date?
    var aiProfileMemberCount: Int = 0

    init(id: UUID, name: String, createdAt: Date,
         userDescription: String? = nil, aiProfileText: String? = nil,
         aiProfileBuiltAt: Date? = nil, aiProfileMemberCount: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.userDescription = userDescription
        self.aiProfileText = aiProfileText
        self.aiProfileBuiltAt = aiProfileBuiltAt
        self.aiProfileMemberCount = aiProfileMemberCount
    }

    convenience init(file: LibraryAlbumFile) {
        self.init(id: file.id, name: file.name, createdAt: file.createdAt,
                  userDescription: file.userDescription,
                  aiProfileText: file.aiProfile?.text,
                  aiProfileBuiltAt: file.aiProfile?.builtAt,
                  aiProfileMemberCount: file.aiProfile?.memberCount ?? 0)
    }

    /// Reconstructs the profile struct for staleness checks.
    var aiProfile: AlbumAIProfile? {
        guard let aiProfileText, let aiProfileBuiltAt else { return nil }
        return AlbumAIProfile(text: aiProfileText, builtAt: aiProfileBuiltAt,
                              memberCount: aiProfileMemberCount)
    }
}
