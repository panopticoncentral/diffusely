import Testing
import Foundation
@testable import Diffusely

@Suite struct SortAssistantLogicTests {

    /// Minimal sidecar metadata for logic tests. Static so other suites
    /// (scanner/service tests in later tasks) can reuse it.
    static func meta(_ id: Int, prompt: String?, albumIDs: [String] = []) -> LibraryItemMetadata {
        let gen = prompt.map {
            GenerationData(
                type: "image",
                meta: GenerationMeta(prompt: $0, negativePrompt: nil, cfgScale: nil,
                                     steps: nil, sampler: nil, seed: nil, clipSkip: nil),
                resources: nil)
        }
        return LibraryItemMetadata(
            schemaVersion: 5, itemID: id, sourcePostID: nil, sourcePostTitle: nil,
            canonicalPostURL: nil, canonicalPageURL: "u", sourceDomain: "civitai.com",
            originalCDNURL: "u", mediaType: .image, mediaFileName: "\(id).jpeg",
            fileByteSize: 1, contentSHA256: "x", width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: gen, publishedAt: nil,
            albumIDs: albumIDs, savedAt: Date(timeIntervalSince1970: TimeInterval(id)),
            savedByAppVersion: "t")
    }

    @Test func selectCandidatesSplitsUnsortedByPrompt() {
        let known = UUID().uuidString
        let dangling = UUID().uuidString   // album that no longer exists
        let metas = [
            Self.meta(1, prompt: "neon city"),                       // candidate
            Self.meta(2, prompt: nil),                               // promptless
            Self.meta(3, prompt: "   "),                             // blank → promptless
            Self.meta(4, prompt: "castle", albumIDs: [known]),       // already sorted
            Self.meta(5, prompt: "forest", albumIDs: [dangling]),    // dangling only → unsorted
        ]
        let result = SortAssistant.selectCandidates(from: metas, knownAlbumIDs: [known])
        #expect(result.candidates == [
            SortAssistant.Candidate(itemID: 1, prompt: "neon city"),
            SortAssistant.Candidate(itemID: 5, prompt: "forest"),
        ])
        #expect(result.promptless == [2, 3])
    }

    @Test func evenlySpacedSampleCoversTheRange() {
        #expect(SortAssistant.evenlySpacedSample([1, 2, 3], limit: 10) == [1, 2, 3])
        let sampled = SortAssistant.evenlySpacedSample(Array(0..<100), limit: 10)
        #expect(sampled.count == 10)
        #expect(sampled.first == 0)
        #expect(sampled.last! >= 90)   // reaches the tail, not just the head
    }

    @Test func profileStalenessIsDoubledMembership() {
        #expect(SortAssistant.profileIsStale(currentMemberCount: 1, profile: nil))
        let profile = AlbumAIProfile(text: "t", builtAt: Date(), memberCount: 10)
        #expect(!SortAssistant.profileIsStale(currentMemberCount: 19, profile: profile))
        #expect(SortAssistant.profileIsStale(currentMemberCount: 20, profile: profile))
    }

    @Test func chunkedSplitsEvenly() {
        #expect(SortAssistant.chunked([1, 2, 3, 4, 5], size: 2) == [[1, 2], [3, 4], [5]])
        #expect(SortAssistant.chunked([Int](), size: 2) == [])
    }

    @Test func profileMessagesIncludeNameDescriptionAndSamples() {
        let messages = SortAssistant.profileMessages(
            albumName: "Cyberpunk", userDescription: "Neon city scenes",
            samplePrompts: ["neon alley, rain", "chrome android"])
        #expect(messages.user.contains("Cyberpunk"))
        #expect(messages.user.contains("Neon city scenes"))
        #expect(messages.user.contains("neon alley, rain"))
        #expect(messages.user.contains("chrome android"))
        #expect(messages.system.contains("\"profile\""))
    }

    @Test func parseProfileResponseExtractsText() {
        #expect(SortAssistant.parseProfileResponse(#"{"profile":"  Neon cityscapes.  "}"#) == "Neon cityscapes.")
        #expect(SortAssistant.parseProfileResponse(#"{"profile":""}"#) == nil)
        #expect(SortAssistant.parseProfileResponse("garbage") == nil)
    }

    @Test func classifyMessagesNumberAlbumsAndListItems() {
        let albums = [
            SortAssistant.AlbumContext(id: UUID(), name: "Cyberpunk", description: "Neon cities"),
            SortAssistant.AlbumContext(id: UUID(), name: "Portraits", description: "Close-up faces"),
        ]
        let batch = [SortAssistant.Candidate(itemID: 7, prompt: "neon alley")]
        let messages = SortAssistant.classifyMessages(albums: albums, batch: batch)
        #expect(messages.user.contains("1. Cyberpunk: Neon cities"))
        #expect(messages.user.contains("2. Portraits: Close-up faces"))
        #expect(messages.user.contains("id 7: neon alley"))
    }

    @Test func parseClassifyResponseMapsAlbumsAndProposals() throws {
        let albumA = SortAssistant.AlbumContext(id: UUID(), name: "A", description: "a")
        let albumB = SortAssistant.AlbumContext(id: UUID(), name: "B", description: "b")
        let batch = [
            SortAssistant.Candidate(itemID: 1, prompt: "p1"),
            SortAssistant.Candidate(itemID: 2, prompt: "p2"),
            SortAssistant.Candidate(itemID: 3, prompt: "p3"),
            SortAssistant.Candidate(itemID: 4, prompt: "p4"),
        ]
        let json = """
        {"items":[
            {"id":1,"albums":[{"n":1,"c":0.9},{"n":2,"c":0.6}]},
            {"id":2,"albums":[{"n":1,"c":0.2}]},
            {"id":3,"albums":[],"new":"Watercolor"},
            {"id":99,"albums":[{"n":1,"c":0.9}]}
        ]}
        """
        let outcome = try #require(SortAssistant.parseClassifyResponse(
            json, albums: [albumA, albumB], batch: batch))
        #expect(outcome.suggestions == [
            SortAssistant.Suggestion(itemID: 1, albumID: albumA.id, confidence: 0.9),
            SortAssistant.Suggestion(itemID: 1, albumID: albumB.id, confidence: 0.6),
        ])
        #expect(outcome.proposals == [SortAssistant.NewAlbumProposal(itemID: 3, name: "Watercolor")])
        // 2: below threshold → unmatched. 4: missing from response → unmatched.
        #expect(Set(outcome.unmatchedItemIDs) == [2, 4])
        #expect(outcome.malformedCount == 1)   // unknown id 99
    }

    @Test func parseClassifyResponseDropsMalformedEntries() throws {
        let album = SortAssistant.AlbumContext(id: UUID(), name: "A", description: "a")
        let batch = [SortAssistant.Candidate(itemID: 1, prompt: "p")]
        // Unknown album number 9, confidence clamped from 1.7 → 1.0.
        let json = #"{"items":[{"id":1,"albums":[{"n":9,"c":0.8},{"n":1,"c":1.7}]}]}"#
        let outcome = try #require(SortAssistant.parseClassifyResponse(json, albums: [album], batch: batch))
        #expect(outcome.suggestions == [SortAssistant.Suggestion(itemID: 1, albumID: album.id, confidence: 1.0)])
        #expect(outcome.malformedCount == 1)
        #expect(SortAssistant.parseClassifyResponse("not json", albums: [album], batch: batch) == nil)
    }

    @Test func filterDropsRejectedSuggestionsAndProposals() {
        let album = UUID()
        var state = SortAssistantState.empty
        state.recordRejection(itemID: 1, albumID: album)
        state.recordNewAlbumRejection(itemID: 3)
        var outcome = SortAssistant.BatchOutcome()
        outcome.suggestions = [
            SortAssistant.Suggestion(itemID: 1, albumID: album, confidence: 0.9),  // rejected
            SortAssistant.Suggestion(itemID: 2, albumID: album, confidence: 0.8),
        ]
        outcome.proposals = [
            SortAssistant.NewAlbumProposal(itemID: 3, name: "X"),                  // rejected
            SortAssistant.NewAlbumProposal(itemID: 4, name: "X"),
        ]
        let filtered = SortAssistant.filter(outcome, against: state)
        #expect(filtered.suggestions.map(\.itemID) == [2])
        #expect(filtered.proposals.map(\.itemID) == [4])
    }

    @Test func reviewGroupsAreOrderedAndSorted() {
        let albumA = SortAssistant.AlbumContext(id: UUID(), name: "A", description: "a")
        let albumB = SortAssistant.AlbumContext(id: UUID(), name: "B", description: "b")
        var outcome = SortAssistant.BatchOutcome()
        outcome.suggestions = [
            SortAssistant.Suggestion(itemID: 1, albumID: albumA.id, confidence: 0.6),
            SortAssistant.Suggestion(itemID: 2, albumID: albumA.id, confidence: 0.9),
            SortAssistant.Suggestion(itemID: 3, albumID: albumB.id, confidence: 0.7),
            SortAssistant.Suggestion(itemID: 4, albumID: albumA.id, confidence: 0.7),
        ]
        outcome.proposals = [
            SortAssistant.NewAlbumProposal(itemID: 5, name: "Watercolor"),
            SortAssistant.NewAlbumProposal(itemID: 6, name: "watercolor"),   // same group, case-insensitive
        ]
        outcome.unmatchedItemIDs = [7]
        let groups = SortAssistant.makeReviewGroups(
            outcome: outcome, albums: [albumA, albumB], promptless: [8])

        #expect(groups.map(\.id) == [
            "album:\(albumA.id.uuidString)", "album:\(albumB.id.uuidString)",
            "new:watercolor", "unmatched", "promptless",
        ])
        // Within an album group: confidence descending.
        #expect(groups[0].entries.map(\.itemID) == [2, 4, 1])
        #expect(groups[2].entries.map(\.itemID) == [5, 6])
        #expect(groups[2].title == "New album: Watercolor")
        #expect(groups[3].entries.map(\.itemID) == [7])
        #expect(groups[4].entries.map(\.itemID) == [8])
    }

    @Test func emptyBucketsProduceNoGroups() {
        let groups = SortAssistant.makeReviewGroups(
            outcome: SortAssistant.BatchOutcome(), albums: [], promptless: [])
        #expect(groups.isEmpty)
    }
}
