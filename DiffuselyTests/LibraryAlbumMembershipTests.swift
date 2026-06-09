import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryAlbumMembershipTests {
    private func meta(_ id: Int, albums: [String]) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albums, savedAt: Date(), savedByAppVersion: "t"
        )
    }

    @Test func denormalizesAlbumIDsFromMetadata() {
        let row = PersistedLibraryItem(metadata: meta(1, albums: ["A", "B"]), downloadStatus: .downloaded)
        #expect(row.albumIDs == ["A", "B"])
        #expect(row.isInAnyAlbum == true)
        #expect(row.belongs(toAlbum: "A"))
        #expect(!row.belongs(toAlbum: "Z"))
    }

    @Test func emptyWhenNoAlbums() {
        let row = PersistedLibraryItem(metadata: meta(2, albums: []), downloadStatus: .downloaded)
        #expect(row.albumIDs == [])
        #expect(row.isInAnyAlbum == false)
    }

    @Test func settingAlbumIDsRoundTripsThroughJoinedString() {
        let row = PersistedLibraryItem(metadata: meta(3, albums: []), downloadStatus: .downloaded)
        row.albumIDs = ["X", "Y"]
        #expect(row.albumIDsJoined.contains("X"))
        #expect(row.albumIDs == ["X", "Y"])
    }
}
