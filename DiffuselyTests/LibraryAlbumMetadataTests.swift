import Testing
import Foundation
@testable import Diffusely

@Suite struct LibraryAlbumMetadataTests {
    private func make(itemID: Int, albumIDs: [String] = []) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: itemID, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(itemID)",
            sourceDomain: "civitai.com",
            originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).jpeg",
            mediaType: .image, mediaFileName: "\(itemID).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil,
            albumIDs: albumIDs, savedAt: Date(), savedByAppVersion: "t"
        )
    }

    @Test func currentSchemaVersionIsFive() {
        #expect(LibraryItemMetadata.currentSchemaVersion == 5)
    }

    @Test func roundTripsAlbumIDs() throws {
        let original = make(itemID: 1, albumIDs: ["A", "B"])
        let data = try LibraryItemMetadata.encoder().encode(original)
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        #expect(decoded.albumIDs == ["A", "B"])
    }

    @Test func legacyV4JSONWithoutAlbumIDsDecodesToEmpty() throws {
        let legacy = """
        { "schemaVersion": 4, "itemID": 9,
          "canonicalPageURL": "https://civitai.com/images/9",
          "sourceDomain": "civitai.com",
          "originalCDNURL": "https://image.civitai.com/x/u/original=true/9.jpeg",
          "mediaType": "image", "mediaFileName": "9.jpeg",
          "fileByteSize": 1, "contentSHA256": "x", "width": 1, "height": 1,
          "nsfwLevel": 1, "author": {},
          "savedAt": "2026-01-01T00:00:00Z", "savedByAppVersion": "old" }
        """.data(using: .utf8)!
        let decoded = try LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: legacy)
        #expect(decoded.albumIDs == [])
    }

    @Test func equalityIsSensitiveToAlbumIDs() {
        let a = make(itemID: 5, albumIDs: ["X"])
        let b = make(itemID: 5, albumIDs: ["X", "Y"])
        #expect(a != b)
    }

    @Test func settingAlbumIDsReturnsCopyWithNewMembership() {
        let a = make(itemID: 7, albumIDs: ["X"])
        let b = a.settingAlbumIDs(["X", "Z"])
        #expect(a.albumIDs == ["X"])           // original unchanged
        #expect(b.albumIDs == ["X", "Z"])
        #expect(b.itemID == 7)                  // everything else preserved
    }
}
