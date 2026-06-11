import Foundation

/// One-off AI profile build for a single album, used by the Edit Description
/// sheet. Scans the container for the album's prompt-bearing members, asks the
/// classifier for a profile paragraph, and returns it WITHOUT persisting —
/// the sheet shows the result for review and saves through
/// `LibraryAlbumService.setAIProfile` only when the user confirms.
struct AlbumProfileBuilder {
    let itemsDirectory: URL
    let classifier: PromptClassifying

    /// Returns nil when the album has no prompt-bearing members or the LLM
    /// call/parse fails. `memberCount` is the prompt-bearing membership size —
    /// the same staleness baseline the Sort Assistant records.
    func buildProfile(
        albumID: UUID,
        albumName: String,
        userDescription: String?
    ) async -> (text: String, memberCount: Int)? {
        let scan = await SortAssistantScanner(itemsDirectory: itemsDirectory).scan()
        let key = albumID.uuidString
        let prompts = scan.items.compactMap { item -> String? in
            guard item.albumIDs.contains(key) else { return nil }
            let prompt = item.generationData?.meta?.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return prompt.isEmpty ? nil : prompt
        }
        guard !prompts.isEmpty else { return nil }

        let messages = SortAssistant.profileMessages(
            albumName: albumName,
            userDescription: userDescription,
            samplePrompts: SortAssistant.evenlySpacedSample(prompts))
        guard let json = try? await classifier.completeJSON(
                system: messages.system, user: messages.user),
              let text = SortAssistant.parseProfileResponse(json) else { return nil }
        return (text, prompts.count)
    }
}
