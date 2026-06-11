import Foundation

/// Pure logic for the Sort Assistant: candidate selection, sampling, staleness,
/// LLM message construction, response parsing, rejection filtering, and review
/// grouping. No I/O — everything here is unit-testable without files or network.
enum SortAssistant {
    /// Suggestions below this confidence land in "Unmatched" instead.
    static let confidenceThreshold = 0.5
    static let profileSampleLimit = 10
    static let classifyBatchSize = 25
    /// Prompts are truncated to this many characters in LLM messages —
    /// generation prompts can run thousands of characters of boilerplate.
    static let promptCharacterLimit = 600

    struct AlbumContext: Equatable {
        let id: UUID
        let name: String
        /// What the classifier is told the album means: aiProfile text, else
        /// the user description, else just the name.
        let description: String
    }

    struct Candidate: Equatable {
        let itemID: Int
        let prompt: String
    }

    struct Suggestion: Equatable {
        let itemID: Int
        let albumID: UUID
        let confidence: Double
    }

    struct NewAlbumProposal: Equatable {
        let itemID: Int
        let name: String
    }

    /// Aggregated classification results (per batch, merged across batches).
    struct BatchOutcome: Equatable {
        var suggestions: [Suggestion] = []
        var proposals: [NewAlbumProposal] = []
        var unmatchedItemIDs: [Int] = []
        var malformedCount: Int = 0

        mutating func merge(_ other: BatchOutcome) {
            suggestions += other.suggestions
            proposals += other.proposals
            unmatchedItemIDs += other.unmatchedItemIDs
            malformedCount += other.malformedCount
        }
    }

    // MARK: - Candidate selection

    /// Splits unsorted items into classifiable candidates (have a prompt) and
    /// prompt-less ids ("Couldn't classify"). "Unsorted" mirrors
    /// `LibrarySortService`'s notInAnyAlbum semantics: membership in a deleted
    /// (unknown) album doesn't count as sorted.
    static func selectCandidates(
        from metadatas: [LibraryItemMetadata],
        knownAlbumIDs: Set<String>
    ) -> (candidates: [Candidate], promptless: [Int]) {
        var candidates: [Candidate] = []
        var promptless: [Int] = []
        for meta in metadatas {
            guard meta.albumIDs.allSatisfy({ !knownAlbumIDs.contains($0) }) else { continue }
            let prompt = meta.generationData?.meta?.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if prompt.isEmpty {
                promptless.append(meta.itemID)
            } else {
                candidates.append(Candidate(itemID: meta.itemID, prompt: prompt))
            }
        }
        return (candidates, promptless)
    }

    // MARK: - Sampling

    /// Up to `limit` elements spread evenly across the array (not just the
    /// head), so profiles see the album's full range, old saves and new.
    static func evenlySpacedSample<T>(_ items: [T], limit: Int = profileSampleLimit) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        return (0..<limit).map { items[(2 * $0 + 1) * items.count / (2 * limit)] }
    }

    // MARK: - Staleness

    /// A profile is stale when the album has at least doubled since it was built.
    static func profileIsStale(currentMemberCount: Int, profile: AlbumAIProfile?) -> Bool {
        guard let profile else { return true }
        return currentMemberCount >= 2 * max(profile.memberCount, 1)
    }

    // MARK: - Chunking

    static func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    // MARK: - Profile building

    static func profileMessages(
        albumName: String, userDescription: String?, samplePrompts: [String]
    ) -> (system: String, user: String) {
        let system = """
        You summarize what a photo album of AI-generated images contains, based on \
        the owner's description and the generation prompts of its members. The \
        owner's description, when present, is authoritative about what the album \
        is for; the member prompts are evidence of it — where they disagree, \
        follow the description. Write one plain-text paragraph (at most 80 words) \
        describing the album's subjects, settings, and visual style. Ignore quality \
        boilerplate (masterpiece, best quality, 8k, lora tags). Respond with ONLY \
        this JSON shape: {"profile":"<paragraph>"}
        """
        var user = "Album name: \(albumName)\n"
        if let userDescription, !userDescription.isEmpty {
            user += "Owner's description: \(userDescription)\n"
        }
        user += "Member prompts:\n"
        for (i, prompt) in samplePrompts.enumerated() {
            user += "\(i + 1). \(String(prompt.prefix(promptCharacterLimit)))\n"
        }
        return (system, user)
    }

    /// LLM responses sometimes arrive fenced (```json … ```) even in JSON
    /// mode; strip the fence so the decoders see bare JSON.
    private static func unfenced(_ json: String) -> String {
        var text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        text = text.replacingOccurrences(
            of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\s*```$"#, with: "", options: .regularExpression)
        return text
    }

    static func parseProfileResponse(_ json: String) -> String? {
        struct Response: Decodable { let profile: String? }
        guard let data = unfenced(json).data(using: .utf8),
              let text = (try? JSONDecoder().decode(Response.self, from: data))?.profile?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Classification

    /// Albums are sent as 1-based numbers (not UUIDs) to save tokens and avoid
    /// transcription errors; the response maps back through array position.
    static func classifyMessages(
        albums: [AlbumContext], batch: [Candidate]
    ) -> (system: String, user: String) {
        let system = """
        You classify AI image generation prompts into a user's photo albums. The \
        albums are numbered. For each item, decide which albums (zero or more) it \
        belongs to, with a confidence from 0 to 1. Only assign an album when the \
        prompt genuinely fits its description. If an item fits no album but clearly \
        suggests an obvious new category, propose a short new album name in "new". \
        Ignore quality boilerplate in prompts (masterpiece, best quality, 8k, lora \
        tags). Respond with ONLY this JSON shape, including every item id exactly \
        once: {"items":[{"id":123,"albums":[{"n":1,"c":0.9}],"new":null}]}
        """
        var user = "Albums:\n"
        for (i, album) in albums.enumerated() {
            user += "\(i + 1). \(album.name): \(album.description)\n"
        }
        user += "\nItems:\n"
        for candidate in batch {
            user += "id \(candidate.itemID): \(String(candidate.prompt.prefix(promptCharacterLimit)))\n"
        }
        return (system, user)
    }

    /// Decodes one classify response. Returns nil when the JSON is undecodable
    /// (the whole batch failed; the caller counts it). Within a decodable
    /// response: malformed entries (unknown/duplicate item ids, out-of-range
    /// album numbers) are dropped and counted; confidence is clamped to 0...1;
    /// suggestions below `confidenceThreshold` are dropped; items with no
    /// surviving suggestion and no proposal — including items the model skipped
    /// entirely — come back unmatched.
    static func parseClassifyResponse(
        _ json: String, albums: [AlbumContext], batch: [Candidate]
    ) -> BatchOutcome? {
        struct Response: Decodable { let items: [Item]? }
        struct Item: Decodable { let id: Int?; let albums: [Score]?; let new: String? }
        struct Score: Decodable { let n: Int?; let c: Double? }

        guard let data = unfenced(json).data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        let validIDs = Set(batch.map(\.itemID))
        var outcome = BatchOutcome()
        var seen = Set<Int>()

        for item in response.items ?? [] {
            guard let id = item.id, validIDs.contains(id), !seen.contains(id) else {
                outcome.malformedCount += 1
                continue
            }
            seen.insert(id)
            var matched = false
            for score in item.albums ?? [] {
                guard let n = score.n, n >= 1, n <= albums.count else {
                    outcome.malformedCount += 1
                    continue
                }
                let confidence = min(max(score.c ?? 0, 0), 1)
                guard confidence >= confidenceThreshold else { continue }
                outcome.suggestions.append(Suggestion(
                    itemID: id, albumID: albums[n - 1].id, confidence: confidence))
                matched = true
            }
            if !matched,
               let name = item.new?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty,
               !["null", "none"].contains(name.lowercased()) {
                outcome.proposals.append(NewAlbumProposal(itemID: id, name: name))
            } else if !matched {
                outcome.unmatchedItemIDs.append(id)
            }
        }
        outcome.unmatchedItemIDs += batch.map(\.itemID).filter { !seen.contains($0) }
        return outcome
    }

    // MARK: - Rejection filtering

    /// Drops suggestions/proposals the user already rejected. Rejected pairs
    /// disappear entirely (not into Unmatched) — the user already declined them.
    static func filter(_ outcome: BatchOutcome, against state: SortAssistantState) -> BatchOutcome {
        var filtered = outcome
        filtered.suggestions = outcome.suggestions.filter {
            !state.isRejected(itemID: $0.itemID, albumID: $0.albumID)
        }
        filtered.proposals = outcome.proposals.filter {
            !state.isNewAlbumRejected(itemID: $0.itemID)
        }
        return filtered
    }

    // MARK: - Review groups

    struct ReviewGroup: Identifiable, Equatable {
        enum Kind: Equatable {
            case album(id: UUID, name: String)
            case newAlbum(name: String)
            case unmatched
            case promptless
        }
        struct Entry: Equatable {
            let itemID: Int
            let confidence: Double
        }
        let id: String
        let kind: Kind
        let entries: [Entry]

        var title: String {
            switch kind {
            case .album(_, let name): return name
            case .newAlbum(let name): return "New album: \(name)"
            case .unmatched: return "Unmatched"
            case .promptless: return "Couldn't classify"
            }
        }
    }

    /// One row per album with suggestions (largest first, entries by confidence
    /// descending), then proposed new albums (grouped case-insensitively by
    /// name, largest first), then Unmatched and Couldn't-classify.
    static func makeReviewGroups(
        outcome: BatchOutcome, albums: [AlbumContext], promptless: [Int]
    ) -> [ReviewGroup] {
        var byAlbum: [UUID: [ReviewGroup.Entry]] = [:]
        for suggestion in outcome.suggestions {
            byAlbum[suggestion.albumID, default: []]
                .append(ReviewGroup.Entry(itemID: suggestion.itemID, confidence: suggestion.confidence))
        }
        var groups: [ReviewGroup] = albums.compactMap { album in
            guard let entries = byAlbum[album.id], !entries.isEmpty else { return nil }
            return ReviewGroup(
                id: "album:\(album.id.uuidString)",
                kind: .album(id: album.id, name: album.name),
                entries: entries.sorted { $0.confidence > $1.confidence })
        }
        groups.sort { $0.entries.count > $1.entries.count }

        var byName: [String: (display: String, entries: [ReviewGroup.Entry])] = [:]
        for proposal in outcome.proposals {
            let key = proposal.name.lowercased()
            byName[key, default: (proposal.name, [])].entries
                .append(ReviewGroup.Entry(itemID: proposal.itemID, confidence: 1)) // Proposals carry no model confidence; 1 is a sentinel the UI must not render as a percentage.
        }
        groups += byName
            .map { key, value in
                ReviewGroup(id: "new:\(key)", kind: .newAlbum(name: value.display), entries: value.entries)
            }
            .sorted {
                $0.entries.count != $1.entries.count
                    ? $0.entries.count > $1.entries.count
                    : $0.id < $1.id
            }

        if !outcome.unmatchedItemIDs.isEmpty {
            groups.append(ReviewGroup(
                id: "unmatched", kind: .unmatched,
                entries: outcome.unmatchedItemIDs.map { .init(itemID: $0, confidence: 0) }))
        }
        if !promptless.isEmpty {
            groups.append(ReviewGroup(
                id: "promptless", kind: .promptless,
                entries: promptless.map { .init(itemID: $0, confidence: 0) }))
        }
        return groups
    }
}
