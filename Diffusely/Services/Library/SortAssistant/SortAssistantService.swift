import Foundation

/// Orchestrates a Sort Assistant run: scan container → build stale album
/// profiles (pausing for user confirmation when any were built) → classify
/// unsorted prompts in batches → review groups. `@MainActor` so SwiftUI can
/// observe progress (mirrors `LibraryDateBackfillService`); blocking file I/O
/// is delegated to the scanner (detached) and the state queue (serial,
/// grey-spinner rule). Results live in memory only — a run is cheap to redo.
/// The scanner skips not-yet-materialized iCloud placeholders, so a freshly
/// synced device may classify a subset; re-running later covers the rest.
@MainActor
final class SortAssistantService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case buildingProfiles(done: Int, total: Int)
        /// Profiles were built this run; awaiting user confirmation/edits.
        case profilesReady
        case classifying(done: Int, total: Int)
        case review
        case failed(String)
    }

    /// A profile built this run, editable in the confirmation step.
    struct BuiltProfile: Identifiable, Equatable {
        let id: UUID          // album id
        let name: String
        var text: String
        let memberCount: Int
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var groups: [SortAssistant.ReviewGroup] = []
    @Published private(set) var failedBatchCount = 0
    /// Profiles appended during `.buildingProfiles`; may only be edited by
    /// the UI while `phase == .profilesReady`.
    @Published var builtProfiles: [BuiltProfile] = []

    private let albumService: LibraryAlbumService
    private let classifier: PromptClassifying
    private let itemsDirectory: URL
    private let stateStore: SortAssistantStateStore
    private var state = SortAssistantState.empty
    private var pendingScan: SortAssistantScanner.ScanResult?
    private var runTask: Task<Void, Never>?

    /// How many classify requests run concurrently.
    private static let maxInFlightBatches = 3

    /// Serial queue for the synchronous coordinated state-file I/O — never the
    /// cooperative pool (grey-spinner rule), mirroring `LibraryAlbumService`.
    private static let stateQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.sortassistant",
        qos: .utility
    )

    init(albumService: LibraryAlbumService, classifier: PromptClassifying, itemsDirectory: URL) {
        self.albumService = albumService
        self.classifier = classifier
        self.itemsDirectory = itemsDirectory
        self.stateStore = SortAssistantStateStore(itemsDirectory: itemsDirectory)
    }

    // MARK: - Task-tracked entry points (UI)

    /// Begins (or retries after `.failed`) a run. The service is otherwise
    /// single-use per presentation: after `.review`, create a fresh instance.
    func start() {
        guard runTask == nil, phase == .idle || isFailed else { return }
        if isFailed {
            phase = .idle
            groups = []
            builtProfiles = []
            failedBatchCount = 0
            pendingScan = nil
        }
        runTask = Task { await run() }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func beginClassification() {
        guard phase == .profilesReady else { return }
        runTask = Task { await confirmProfiles() }
    }

    func cancel() { runTask?.cancel() }

    // MARK: - Run

    /// Internal (not private) so tests drive it directly without task polling.
    func run() async {
        phase = .scanning
        let scan = await SortAssistantScanner(itemsDirectory: itemsDirectory).scan()
        let store = stateStore
        state = await Self.onStateQueue { store.read() }

        // Prompts of every prompt-bearing member, per album uuidString.
        var memberPrompts: [String: [String]] = [:]
        for item in scan.items {
            guard let prompt = item.generationData?.meta?.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { continue }
            for albumID in item.albumIDs {
                memberPrompts[albumID, default: []].append(prompt)
            }
        }

        // Build profiles for stale albums that have sampleable members.
        let stale = scan.albums.filter { file in
            let count = memberPrompts[file.id.uuidString]?.count ?? 0
            return count > 0 && SortAssistant.profileIsStale(
                currentMemberCount: count, profile: file.aiProfile)
        }
        builtProfiles = []
        for (i, file) in stale.enumerated() {
            if Task.isCancelled { phase = .idle; runTask = nil; return }
            phase = .buildingProfiles(done: i, total: stale.count)
            let prompts = memberPrompts[file.id.uuidString] ?? []
            let messages = SortAssistant.profileMessages(
                albumName: file.name,
                userDescription: file.userDescription,
                samplePrompts: SortAssistant.evenlySpacedSample(prompts))
            guard let json = try? await classifier.completeJSON(system: messages.system, user: messages.user),
                  let text = SortAssistant.parseProfileResponse(json) else { continue }
            builtProfiles.append(BuiltProfile(
                id: file.id, name: file.name, text: text, memberCount: prompts.count))
        }

        if builtProfiles.isEmpty {
            await classify(scan, profileOverrides: [:])
        } else {
            // Pause for the confirmation step; classification continues from
            // confirmProfiles() with any user edits applied.
            pendingScan = scan
            phase = .profilesReady
        }
        runTask = nil
    }

    /// Persists the (possibly user-edited) built profiles, then classifies.
    /// Internal so tests can await it directly.
    func confirmProfiles() async {
        guard let scan = pendingScan else { return }
        phase = .classifying(done: 0, total: 0)
        pendingScan = nil
        var overrides: [UUID: String] = [:]
        for profile in builtProfiles {
            let trimmed = profile.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            overrides[profile.id] = trimmed
            await albumService.setAIProfile(profile.id, AlbumAIProfile(
                text: trimmed, builtAt: Date(), memberCount: profile.memberCount))
        }
        await classify(scan, profileOverrides: overrides)
        runTask = nil
    }

    private func classify(
        _ scan: SortAssistantScanner.ScanResult,
        profileOverrides: [UUID: String]
    ) async {
        let albums = scan.albums.map { file in
            SortAssistant.AlbumContext(
                id: file.id,
                name: file.name,
                description: profileOverrides[file.id]
                    ?? file.aiProfile?.text
                    ?? file.userDescription
                    ?? file.name)
        }
        let knownIDs = Set(scan.albums.map { $0.id.uuidString })
        let (candidates, promptless) = SortAssistant.selectCandidates(
            from: scan.items, knownAlbumIDs: knownIDs)
        let batches = SortAssistant.chunked(candidates, size: SortAssistant.classifyBatchSize)

        var outcome = SortAssistant.BatchOutcome()
        var done = 0
        failedBatchCount = 0
        phase = .classifying(done: 0, total: batches.count)

        let currentClassifier = classifier
        await withTaskGroup(of: SortAssistant.BatchOutcome?.self) { group in
            var next = 0
            func enqueue() {
                // Cancellation stops NEW batches; in-flight ones finish and
                // their results are kept (partial review is fine).
                guard next < batches.count, !Task.isCancelled else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    let messages = SortAssistant.classifyMessages(albums: albums, batch: batch)
                    guard let json = try? await currentClassifier.completeJSON(
                        system: messages.system, user: messages.user) else { return nil }
                    return SortAssistant.parseClassifyResponse(json, albums: albums, batch: batch)
                }
            }
            for _ in 0..<min(Self.maxInFlightBatches, batches.count) { enqueue() }
            for await result in group {
                done += 1
                phase = .classifying(done: done, total: batches.count)
                if let result { outcome.merge(result) } else { failedBatchCount += 1 }
                enqueue()
            }
        }

        if !batches.isEmpty && failedBatchCount == batches.count {
            phase = .failed("All \(batches.count) classification request(s) failed. "
                + "Check your OpenRouter API key and model in Settings.")
            return
        }
        let filtered = SortAssistant.filter(outcome, against: state)
        groups = SortAssistant.makeReviewGroups(
            outcome: filtered, albums: albums, promptless: promptless)
        phase = .review
    }

    // MARK: - Accept

    /// Applies the user's review of one group: adds membership for the
    /// selected ids (through the existing LibraryAlbumService write path),
    /// records rejections for the deselected ids, persists the state file,
    /// and removes the group from the pending list. For a new-album group the
    /// album is created first. A group for an album deleted since classify is
    /// dropped (no membership written).
    func accept(group: SortAssistant.ReviewGroup, selectedIDs: Set<Int>) async {
        // A stale group reference (double-tap, or a group already accepted)
        // must not re-run membership writes — .newAlbum would create a
        // duplicate album.
        guard groups.contains(where: { $0.id == group.id }) else { return }
        let all = group.entries.map(\.itemID)
        let selected = all.filter { selectedIDs.contains($0) }
        let rejected = all.filter { !selectedIDs.contains($0) }

        switch group.kind {
        case .album(let id, _):
            if !selected.isEmpty, await albumService.albumExists(id) {
                await albumService.addItems(selected, toAlbum: id)
            }
            for itemID in rejected { state.recordRejection(itemID: itemID, albumID: id) }
        case .newAlbum(let name):
            if !selected.isEmpty {
                let id = await albumService.createAlbum(name: name)
                await albumService.addItems(selected, toAlbum: id)
            }
            for itemID in rejected { state.recordNewAlbumRejection(itemID: itemID) }
        case .unmatched, .promptless:
            break
        }

        let snapshot = state
        let store = stateStore
        await Self.onStateQueue { try? store.write(snapshot) }
        groups.removeAll { $0.id == group.id }
    }

    // MARK: - Test seams

    /// Test seam: seeds review groups without running a classification.
    func setGroupsForTesting(_ newGroups: [SortAssistant.ReviewGroup]) {
        groups = newGroups
    }

    // MARK: - State queue

    private static func onStateQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            stateQueue.async { cont.resume(returning: work()) }
        }
    }
}
