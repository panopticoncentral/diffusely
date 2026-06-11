# Sort Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-app Sort Assistant that classifies unsorted Library items into albums using LLM classification of their generation prompts (OpenRouter / DeepSeek), with a grouped review UI — nothing is filed without user approval.

**Architecture:** Album files gain an optional user description and an LLM-built profile. A pure-logic layer (`SortAssistant` enum) handles sampling, prompt construction, response parsing, and review grouping; a `@MainActor` orchestration service (`SortAssistantService`) drives scan → profile build → batched classification → review, observable by SwiftUI. Accepted suggestions write through the existing `LibraryAlbumService`; rejections persist in a `sort-assistant-state.json` container file so re-runs don't resurface them.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing (`@Suite`/`@Test`/`#expect`), URLSession against OpenRouter's chat-completions API.

**Spec:** `docs/superpowers/specs/2026-06-10-sort-assistant-design.md`

**Deviations from spec (intentional, decided while planning):**
- `AlbumAIProfile` stores `memberCount` (album membership size when the profile was built) instead of `sampleCount`. The spec's staleness rule is "membership doubled since build", which needs the membership baseline, not the sample size. The baseline counts prompt-bearing members only (those are what profiles are built from).
- The "N unsorted" badge requirement is satisfied by the existing "Not in any Album" smart tile count in `AlbumsBrowserView`; no separate badge is added.

**Project facts the engineer needs:**
- The Xcode project uses filesystem-synchronized groups: new `.swift` files under `Diffusely/` and `DiffuselyTests/` are picked up automatically. No project-file edits.
- Build: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
- Test (suite-scoped): `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/<SuiteName> -quiet`
- **Grey-spinner rule (critical, documented all over the codebase):** synchronous `NSFileCoordinator` / blocking file I/O must run on a dedicated serial `DispatchQueue` bridged with `withCheckedContinuation` — never on the Swift-concurrency cooperative pool or main actor. Follow the existing patterns in `LibraryAlbumService` / `LibraryIndexService`.
- The container holds: item sidecars `{itemID}.json`, media `{itemID}.jpeg/.mp4`, album files `album-{uuid}.json`. We add `sort-assistant-state.json`. The reconcile scan tolerates unknown JSON (it fails to decode as an item sidecar and is skipped), and `NSMetadataQuery` firing on state-file writes just schedules a debounced no-op reconcile — harmless.

---

### Task 1: `AlbumAIProfile` + new `LibraryAlbumFile` fields

**Files:**
- Modify: `Diffusely/Services/Library/LibraryAlbumFile.swift`
- Test: `DiffuselyTests/LibraryAlbumFileTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the existing `@Suite struct LibraryAlbumFileTests`:

```swift
@Test func decodesLegacyFileWithoutProfileFields() throws {
    let id = UUID()
    let json = """
    {"id":"\(id.uuidString)","name":"Faves","createdAt":"2026-01-01T00:00:00Z"}
    """
    let file = try LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: Data(json.utf8))
    #expect(file.id == id)
    #expect(file.userDescription == nil)
    #expect(file.aiProfile == nil)
}

@Test func profileFieldsRoundTripThroughStore() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = LibraryAlbumStore(itemsDirectory: dir)
    var file = LibraryAlbumFile(id: UUID(), name: "Cyberpunk", createdAt: Date(timeIntervalSince1970: 10))
    file.userDescription = "Neon city scenes"
    file.aiProfile = AlbumAIProfile(text: "Futuristic neon cityscapes…",
                                    builtAt: Date(timeIntervalSince1970: 20),
                                    memberCount: 42)
    try store.write(file)
    let read = try #require(store.read(id: file.id))
    #expect(read.userDescription == "Neon city scenes")
    #expect(read.aiProfile?.memberCount == 42)
    #expect(read == file)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/LibraryAlbumFileTests -quiet`
Expected: compile error — `AlbumAIProfile` not defined, `userDescription` not a member.

- [ ] **Step 3: Implement**

In `Diffusely/Services/Library/LibraryAlbumFile.swift`, add above `LibraryAlbumFile`:

```swift
/// LLM-distilled description of what an album contains (Sort Assistant).
/// Stored on the album file so it syncs across devices and survives index
/// rebuilds. `memberCount` is the number of prompt-bearing members when the
/// profile was built — the staleness baseline ("rebuild when membership has
/// doubled").
struct AlbumAIProfile: Codable, Equatable {
    var text: String
    var builtAt: Date
    var memberCount: Int
}
```

Change `LibraryAlbumFile` to:

```swift
struct LibraryAlbumFile: Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// Optional owner-written description; sharpens Sort Assistant profiles.
    var userDescription: String?
    /// LLM-built content profile (Sort Assistant). Nil until first built.
    var aiProfile: AlbumAIProfile?

    init(id: UUID, name: String, createdAt: Date,
         userDescription: String? = nil, aiProfile: AlbumAIProfile? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.userDescription = userDescription
        self.aiProfile = aiProfile
    }
    // keep the existing decoder()/encoder() statics unchanged
}
```

Synthesized `Codable` decodes missing optional keys as nil, so legacy `album-{uuid}.json` files (id/name/createdAt only) decode unchanged. The explicit init keeps every existing call site source-compatible.

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS (all `LibraryAlbumFileTests`).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryAlbumFile.swift DiffuselyTests/LibraryAlbumFileTests.swift
git commit -m "Add userDescription and AI profile fields to album files"
```

---

### Task 2: Denormalize profile onto `PersistedAlbum`; album-service profile writes

**Files:**
- Modify: `Diffusely/Models/Persistence/PersistedAlbum.swift`
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (`upsertAlbum`, `applyAlbums`)
- Modify: `Diffusely/Services/Library/LibraryAlbumService.swift`
- Test: `DiffuselyTests/LibraryAlbumServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `@Suite struct LibraryAlbumServiceTests` (it already has `makeContainer()` / `tempDir()` helpers):

```swift
@Test func descriptionAndProfilePersistToFileAndIndex() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let container = try makeContainer()
    let index = LibraryIndexService(modelContainer: container)
    let svc = LibraryAlbumService(index: index, itemsDirectory: { dir })
    let album = await svc.createAlbum(name: "Cyberpunk")

    await svc.setUserDescription(album, "Neon city scenes")
    let profile = AlbumAIProfile(text: "Futuristic neon cityscapes", builtAt: Date(), memberCount: 7)
    await svc.setAIProfile(album, profile)

    let file = try #require(LibraryAlbumStore(itemsDirectory: dir).read(id: album))
    #expect(file.userDescription == "Neon city scenes")
    #expect(file.aiProfile == profile)

    let row = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>()).first)
    #expect(row.userDescription == "Neon city scenes")
    #expect(row.aiProfileText == "Futuristic neon cityscapes")
    #expect(row.aiProfileMemberCount == 7)

    #expect(await svc.albumExists(album))
    #expect(!(await svc.albumExists(UUID())))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/LibraryAlbumServiceTests -quiet`
Expected: compile error — `setUserDescription` / `setAIProfile` / `albumExists` / new `PersistedAlbum` fields don't exist.

- [ ] **Step 3: Extend `PersistedAlbum`**

Replace the class body in `Diffusely/Models/Persistence/PersistedAlbum.swift`:

```swift
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
```

New optional/defaulted scalars are a lightweight SwiftData migration — no migration plan needed (matches how `albumIDsJoined` was added).

- [ ] **Step 4: Switch the index to file-based album upserts**

In `Diffusely/Services/Library/LibraryIndexService.swift`, replace `upsertAlbum(id:name:createdAt:)` with:

```swift
func upsertAlbum(_ file: LibraryAlbumFile) {
    bumpMutationEpoch()
    if let existing = fetchAlbum(id: file.id) {
        Self.apply(file, to: existing)
    } else {
        modelContext.insert(PersistedAlbum(file: file))
    }
    try? modelContext.save()
}

/// Copies all denormalized fields from an album file onto an index row.
/// Returns whether anything observable changed (drives the albumsVersion
/// reload signal). Static + nonisolated-safe: pure in-memory work.
@discardableResult
private static func apply(_ file: LibraryAlbumFile, to row: PersistedAlbum) -> Bool {
    let changed = row.name != file.name || row.createdAt != file.createdAt
        || row.userDescription != file.userDescription
        || row.aiProfileText != file.aiProfile?.text
    row.name = file.name
    row.createdAt = file.createdAt
    row.userDescription = file.userDescription
    row.aiProfileText = file.aiProfile?.text
    row.aiProfileBuiltAt = file.aiProfile?.builtAt
    row.aiProfileMemberCount = file.aiProfile?.memberCount ?? 0
    return changed
}
```

In `applyAlbums(_ scan:)`, replace the per-file loop body with the helper:

```swift
for file in scan.albums {
    if let row = byID[file.id] {
        if Self.apply(file, to: row) { changed = true }
    } else {
        let row = PersistedAlbum(file: file)
        modelContext.insert(row)
        byID[file.id] = row
        changed = true
    }
}
```

(The vanished-album pruning loop below it is unchanged.)

Then find every remaining caller of the old signature and update it: `grep -rn "upsertAlbum" Diffusely DiffuselyTests`. Expected callers: `LibraryAlbumService.createAlbum` / `renameAlbum` (fixed in Step 5) and possibly index-write tests — wrap their arguments in a `LibraryAlbumFile`, e.g. `await index.upsertAlbum(LibraryAlbumFile(id: id, name: "A", createdAt: date))`.

- [ ] **Step 5: Extend `LibraryAlbumService`**

In `Diffusely/Services/Library/LibraryAlbumService.swift`:

In `createAlbum`, replace `await index.upsertAlbum(id: id, name: file.name, createdAt: file.createdAt)` with `await index.upsertAlbum(file)`.

Replace `renameAlbum` and add the new mutators (all reuse one file-mutation helper):

```swift
func renameAlbum(_ id: UUID, to newName: String) async {
    await mutateAlbumFile(id) { $0.name = newName }
}

func setUserDescription(_ id: UUID, _ description: String?) async {
    await mutateAlbumFile(id) { $0.userDescription = description }
}

func setAIProfile(_ id: UUID, _ profile: AlbumAIProfile) async {
    await mutateAlbumFile(id) { $0.aiProfile = profile }
}

/// True when the album file exists in the container. Sort Assistant uses this
/// to drop suggestions for albums deleted between classify and accept.
func albumExists(_ id: UUID) async -> Bool {
    guard let dir = await resolveDirectory() else { return false }
    return await Self.run { LibraryAlbumStore(itemsDirectory: dir).read(id: id) != nil }
}

/// Reads the album file, applies `mutate`, rewrites it, and refreshes the
/// index row — file I/O on the dedicated serial queue (grey-spinner rule).
private func mutateAlbumFile(_ id: UUID, _ mutate: @escaping (inout LibraryAlbumFile) -> Void) async {
    guard let dir = await resolveDirectory() else { return }
    let store = LibraryAlbumStore(itemsDirectory: dir)
    guard var file = await Self.run({ store.read(id: id) }) else { return }
    mutate(&file)
    let final = file
    await Self.run { try? store.write(final) }
    await index.upsertAlbum(final)
}
```

- [ ] **Step 6: Run the album test suites**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/LibraryAlbumServiceTests -only-testing:DiffuselyTests/LibraryIndexAlbumWriteTests -only-testing:DiffuselyTests/LibraryAlbumReconcileTests -only-testing:DiffuselyTests/PersistedAlbumTests -quiet`
Expected: PASS. If any suite fails to compile on the old `upsertAlbum` signature, update those call sites as in Step 4.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Denormalize album description/AI profile into the index; album service profile writes"
```

---

### Task 3: Rejection-memory state file

**Files:**
- Create: `Diffusely/Services/Library/SortAssistant/SortAssistantState.swift`
- Test: `DiffuselyTests/SortAssistantStateTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/SortAssistantStateTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct SortAssistantStateTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func rejectionRecordingAndLookup() {
        var state = SortAssistantState.empty
        let album = UUID()
        #expect(!state.isRejected(itemID: 5, albumID: album))
        state.recordRejection(itemID: 5, albumID: album)
        state.recordRejection(itemID: 5, albumID: album)   // idempotent
        #expect(state.isRejected(itemID: 5, albumID: album))
        #expect(!state.isRejected(itemID: 6, albumID: album))
        #expect(state.rejected["5"] == [album.uuidString])

        #expect(!state.isNewAlbumRejected(itemID: 5))
        state.recordNewAlbumRejection(itemID: 5)
        state.recordNewAlbumRejection(itemID: 5)           // idempotent
        #expect(state.isNewAlbumRejected(itemID: 5))
        #expect(state.rejectedNewAlbum == ["5"])
    }

    @Test func storeRoundTripsAndDefaultsToEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SortAssistantStateStore(itemsDirectory: dir)
        #expect(store.read() == .empty)            // missing file

        var state = SortAssistantState.empty
        state.recordRejection(itemID: 11, albumID: UUID())
        try store.write(state)
        #expect(store.read() == state)
    }

    @Test func corruptFileReadsAsEmpty() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(
            to: dir.appendingPathComponent(SortAssistantStateStore.fileName))
        #expect(SortAssistantStateStore(itemsDirectory: dir).read() == .empty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/SortAssistantStateTests -quiet`
Expected: compile error — types not defined.

- [ ] **Step 3: Implement**

Create `Diffusely/Services/Library/SortAssistant/SortAssistantState.swift`:

```swift
import Foundation

/// Sort Assistant rejection memory: which (item, album) suggestions and which
/// new-album proposals the user has declined, so re-runs don't resurface them.
/// Persisted as `sort-assistant-state.json` in the container — survives index
/// rebuilds and syncs across devices. Item ids are stringified for stable JSON
/// keys ([Int: …] would encode as a flat array).
struct SortAssistantState: Codable, Equatable {
    var schemaVersion: Int
    /// itemID (string) → rejected album UUID strings.
    var rejected: [String: [String]]
    /// itemIDs (strings) rejected as "new album" suggestions.
    var rejectedNewAlbum: [String]

    static let empty = SortAssistantState(schemaVersion: 1, rejected: [:], rejectedNewAlbum: [])

    func isRejected(itemID: Int, albumID: UUID) -> Bool {
        rejected[String(itemID)]?.contains(albumID.uuidString) ?? false
    }

    func isNewAlbumRejected(itemID: Int) -> Bool {
        rejectedNewAlbum.contains(String(itemID))
    }

    mutating func recordRejection(itemID: Int, albumID: UUID) {
        let key = String(itemID)
        var list = rejected[key] ?? []
        guard !list.contains(albumID.uuidString) else { return }
        list.append(albumID.uuidString)
        rejected[key] = list
    }

    mutating func recordNewAlbumRejection(itemID: Int) {
        let key = String(itemID)
        guard !rejectedNewAlbum.contains(key) else { return }
        rejectedNewAlbum.append(key)
    }
}

/// Coordinated reader/writer for the state file, mirroring `LibraryAlbumStore`:
/// synchronous `NSFileCoordinator` I/O that the CALLER must dispatch onto a
/// dedicated serial queue, never the cooperative pool or main actor
/// (grey-spinner rule).
struct SortAssistantStateStore {
    let itemsDirectory: URL

    static let fileName = "sort-assistant-state.json"

    private var url: URL {
        itemsDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Missing or unreadable file reads as `.empty` — losing rejection memory
    /// only means some declined suggestions reappear once; never fatal.
    func read() -> SortAssistantState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SortAssistantState.self, from: data) else {
            return .empty
        }
        return state
    }

    func write(_ state: SortAssistantState) throws {
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(state)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { dest in
            do { try json.write(to: dest, options: .atomic) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/SortAssistant/SortAssistantState.swift DiffuselyTests/SortAssistantStateTests.swift
git commit -m "Add Sort Assistant rejection-memory state file"
```

---

### Task 4: OpenRouter config + classifier client

**Files:**
- Create: `Diffusely/Services/Networking/OpenRouterService.swift`
- Test: `DiffuselyTests/OpenRouterServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/OpenRouterServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct OpenRouterServiceTests {
    @Test func requestCarriesModelMessagesAndJSONMode() throws {
        let request = try OpenRouterClassifier.makeRequest(
            apiKey: "sk-test", model: "deepseek/deepseek-v4",
            system: "sys", user: "usr")
        #expect(request.url == OpenRouterClassifier.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "deepseek/deepseek-v4")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[0]["content"] == "sys")
        #expect(messages?[1]["role"] == "user")
        #expect(messages?[1]["content"] == "usr")
        let format = body?["response_format"] as? [String: String]
        #expect(format?["type"] == "json_object")
    }

    @Test func extractsAssistantContent() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"{\\"ok\\":true}"}}]}
        """.utf8)
        #expect(try OpenRouterClassifier.extractContent(from: data) == "{\"ok\":true}")
    }

    @Test func malformedResponseThrows() {
        #expect(throws: OpenRouterError.malformedResponse) {
            try OpenRouterClassifier.extractContent(from: Data("{}".utf8))
        }
        #expect(throws: OpenRouterError.malformedResponse) {
            try OpenRouterClassifier.extractContent(from: Data("not json".utf8))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/OpenRouterServiceTests -quiet`
Expected: compile error — types not defined.

- [ ] **Step 3: Implement**

Create `Diffusely/Services/Networking/OpenRouterService.swift`:

```swift
import Foundation

/// Settings-backed OpenRouter configuration, mirroring `APIKeyManager`
/// (UserDefaults-backed `@Published` singleton; deliberately untested like its
/// sibling — it is a thin UserDefaults wrapper).
@MainActor
final class OpenRouterConfig: ObservableObject {
    static let shared = OpenRouterConfig()
    static let apiKeyDefaultsKey = "openrouter_api_key"
    static let modelDefaultsKey = "openrouter_model"
    /// OpenRouter model slug. IMPLEMENTER: verify the current DeepSeek V4 slug
    /// at https://openrouter.ai/models before shipping; the user can edit it
    /// in Settings either way.
    static let defaultModel = "deepseek/deepseek-v4"

    @Published var apiKey: String? {
        didSet {
            if let key = apiKey, !key.isEmpty {
                UserDefaults.standard.set(key, forKey: Self.apiKeyDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.apiKeyDefaultsKey)
            }
        }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey) }
    }

    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    private init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey)
        self.model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
    }
}

/// Seam for the Sort Assistant's LLM calls so the pipeline is testable with a
/// stub (mirrors `LibraryDateBackfillService.FetchImageProvider`).
protocol PromptClassifying: Sendable {
    /// One chat completion in JSON mode; returns the assistant message content.
    func completeJSON(system: String, user: String) async throws -> String
}

enum OpenRouterError: Error, Equatable {
    case badStatus(Int)
    case malformedResponse
}

/// Thin OpenRouter chat-completions client.
struct OpenRouterClassifier: PromptClassifying {
    let apiKey: String
    let model: String
    var session: URLSession = .shared

    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static func makeRequest(apiKey: String, model: String, system: String, user: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.1,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func extractContent(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let content = (try? JSONDecoder().decode(Response.self, from: data))?
            .choices?.first?.message?.content, !content.isEmpty else {
            throw OpenRouterError.malformedResponse
        }
        return content
    }

    func completeJSON(system: String, user: String) async throws -> String {
        let request = try Self.makeRequest(apiKey: apiKey, model: model, system: system, user: user)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenRouterError.badStatus(http.statusCode)
        }
        return try Self.extractContent(from: data)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Networking/OpenRouterService.swift DiffuselyTests/OpenRouterServiceTests.swift
git commit -m "Add OpenRouter config and chat-completions classifier client"
```

---

### Task 5: Pure logic — candidates, sampling, staleness, chunking

**Files:**
- Create: `Diffusely/Services/Library/SortAssistant/SortAssistantLogic.swift`
- Test: `DiffuselyTests/SortAssistantLogicTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/SortAssistantLogicTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct SortAssistantLogicTests {

    /// Minimal sidecar metadata for logic tests.
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DiffuselyTests/SortAssistantLogicTests -quiet`
Expected: compile error — `SortAssistant` not defined.

- [ ] **Step 3: Implement**

Create `Diffusely/Services/Library/SortAssistant/SortAssistantLogic.swift`:

```swift
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

    /// Up to `limit` elements spread evenly across the array (not just the
    /// head), so profiles see the album's full range, old saves and new.
    static func evenlySpacedSample<T>(_ items: [T], limit: Int = profileSampleLimit) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        return (0..<limit).map { items[$0 * items.count / limit] }
    }

    /// A profile is stale when the album has at least doubled since it was built.
    static func profileIsStale(currentMemberCount: Int, profile: AlbumAIProfile?) -> Bool {
        guard let profile else { return true }
        return currentMemberCount >= 2 * max(profile.memberCount, 1)
    }

    static func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/SortAssistant/SortAssistantLogic.swift DiffuselyTests/SortAssistantLogicTests.swift
git commit -m "Add Sort Assistant pure logic: candidates, sampling, staleness, chunking"
```

---

### Task 6: Pure logic — LLM messages and response parsing

**Files:**
- Modify: `Diffusely/Services/Library/SortAssistant/SortAssistantLogic.swift`
- Test: `DiffuselyTests/SortAssistantLogicTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SortAssistantLogicTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:DiffuselyTests/SortAssistantLogicTests -quiet`
Expected: compile error — new functions not defined.

- [ ] **Step 3: Implement**

Add inside `enum SortAssistant`:

```swift
    // MARK: - Profile building

    static func profileMessages(
        albumName: String, userDescription: String?, samplePrompts: [String]
    ) -> (system: String, user: String) {
        let system = """
        You summarize what a photo album of AI-generated images contains, based on \
        the generation prompts of its members. Write one plain-text paragraph (at \
        most 80 words) describing the album's subjects, settings, and visual style. \
        Ignore quality boilerplate (masterpiece, best quality, 8k, lora tags). \
        Respond with ONLY this JSON shape: {"profile":"<paragraph>"}
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

    static func parseProfileResponse(_ json: String) -> String? {
        struct Response: Decodable { let profile: String? }
        guard let data = json.data(using: .utf8),
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

        guard let data = json.data(using: .utf8),
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
                guard let n = score.n, (1...albums.count).contains(n) else {
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
               !name.isEmpty {
                outcome.proposals.append(NewAlbumProposal(itemID: id, name: name))
            } else if !matched {
                outcome.unmatchedItemIDs.append(id)
            }
        }
        outcome.unmatchedItemIDs += batch.map(\.itemID).filter { !seen.contains($0) }
        return outcome
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Sort Assistant LLM message construction and response parsing"
```

---

### Task 7: Pure logic — rejection filtering and review groups

**Files:**
- Modify: `Diffusely/Services/Library/SortAssistant/SortAssistantLogic.swift`
- Test: `DiffuselyTests/SortAssistantLogicTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SortAssistantLogicTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:DiffuselyTests/SortAssistantLogicTests -quiet`
Expected: compile error — `filter`, `makeReviewGroups`, `ReviewGroup` not defined.

- [ ] **Step 3: Implement**

Add inside `enum SortAssistant`:

```swift
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
                .append(ReviewGroup.Entry(itemID: proposal.itemID, confidence: 1))
        }
        groups += byName
            .map { key, value in
                ReviewGroup(id: "new:\(key)", kind: .newAlbum(name: value.display), entries: value.entries)
            }
            .sorted { $0.entries.count > $1.entries.count }

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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS (all `SortAssistantLogicTests`).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Sort Assistant rejection filtering and review grouping"
```

---

### Task 8: Container scanner

**Files:**
- Create: `Diffusely/Services/Library/SortAssistant/SortAssistantScanner.swift`
- Test: `DiffuselyTests/SortAssistantScannerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/SortAssistantScannerTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct SortAssistantScannerTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func scanSeparatesItemsAlbumsAndIgnoresStateFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let writer = LibraryFileWriter(itemsDirectory: dir)
        let meta = SortAssistantLogicTests.meta(11, prompt: "neon alley")
        let tmp = dir.appendingPathComponent("dl.tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)

        let album = LibraryAlbumFile(id: UUID(), name: "Cyberpunk", createdAt: Date())
        try LibraryAlbumStore(itemsDirectory: dir).write(album)

        try SortAssistantStateStore(itemsDirectory: dir).write(.empty)
        // Corrupt stray JSON must be skipped, not crash the scan.
        try Data("junk".utf8).write(to: dir.appendingPathComponent("999.json"))

        let result = await SortAssistantScanner(itemsDirectory: dir).scan()
        #expect(result.items.map(\.itemID) == [11])
        #expect(result.albums.map(\.id) == [album.id])
    }
}
```

Note: this reuses `SortAssistantLogicTests.meta` — that helper is `static` (declared so in Task 5).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test ... -only-testing:DiffuselyTests/SortAssistantScannerTests -quiet`
Expected: compile error — `SortAssistantScanner` not defined.

- [ ] **Step 3: Implement**

Create `Diffusely/Services/Library/SortAssistant/SortAssistantScanner.swift`:

```swift
import Foundation

/// One-shot container scan for the Sort Assistant: every readable item sidecar
/// plus every album file. Mirrors `FileLibraryBackfillSidecarStore`'s
/// detached-task pattern so the directory walk and JSON decodes never run on
/// the caller's actor. Dataless iCloud placeholders are skipped — their
/// prompts aren't readable without a blocking FileProvider download; they'll
/// be picked up by a later run once materialized.
struct SortAssistantScanner {
    let itemsDirectory: URL

    struct ScanResult: Sendable {
        var items: [LibraryItemMetadata] = []
        var albums: [LibraryAlbumFile] = []
    }

    func scan() async -> ScanResult {
        let directory = itemsDirectory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var result = ScanResult()
            for url in urls where url.pathExtension == "json" {
                guard !LibraryIndexService.isDatalessPlaceholder(url) else { continue }
                let name = url.lastPathComponent
                if LibraryAlbumStore.albumID(fromFileName: name) != nil {
                    if let data = try? Data(contentsOf: url),
                       let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data) {
                        result.albums.append(file)
                    }
                    continue
                }
                guard name != SortAssistantStateStore.fileName else { continue }
                if let data = try? Data(contentsOf: url),
                   let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data) {
                    result.items.append(meta)
                }
            }
            // Directory enumeration order is arbitrary; sort so candidate
            // batching is deterministic (stable batches across runs and in tests).
            result.items.sort { $0.itemID < $1.itemID }
            result.albums.sort { $0.createdAt < $1.createdAt }
            return result
        }.value
    }
}
```

If the compiler requires `LibraryItemMetadata` / `LibraryAlbumFile` to be `Sendable` for the `ScanResult` hop, add `extension LibraryItemMetadata: @unchecked Sendable {}` only as a last resort — both are value types of value types, so plain conformance (`Sendable`) should be accepted or already implicit.

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/SortAssistant/SortAssistantScanner.swift DiffuselyTests/SortAssistantScannerTests.swift
git commit -m "Add Sort Assistant container scanner"
```

---

### Task 9: `SortAssistantService` — run orchestration

**Files:**
- Create: `Diffusely/Services/Library/SortAssistant/SortAssistantService.swift`
- Test: `DiffuselyTests/SortAssistantServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/SortAssistantServiceTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Diffusely

/// Test seam: scripted classifier.
final class StubClassifier: PromptClassifying, @unchecked Sendable {
    let handler: @Sendable (String, String) async throws -> String
    init(_ handler: @escaping @Sendable (String, String) async throws -> String) {
        self.handler = handler
    }
    func completeJSON(system: String, user: String) async throws -> String {
        try await handler(system, user)
    }
}

@Suite struct SortAssistantServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self, PersistedAlbum.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func commitItem(_ id: Int, prompt: String?, albumIDs: [String] = [], in dir: URL) throws {
        let writer = LibraryFileWriter(itemsDirectory: dir)
        let meta = SortAssistantLogicTests.meta(id, prompt: prompt, albumIDs: albumIDs)
        let tmp = dir.appendingPathComponent("dl-\(id).tmp"); try Data("b".utf8).write(to: tmp)
        try writer.commit(metadata: meta, mediaTempURL: tmp)
    }
    private func makeAlbumService(_ container: ModelContainer, dir: URL) -> LibraryAlbumService {
        LibraryAlbumService(index: LibraryIndexService(modelContainer: container), itemsDirectory: { dir })
    }

    @MainActor
    @Test func freshProfilesGoStraightToReview() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)

        // Album with a FRESH profile (memberCount 5, only 1 actual member).
        let albumID = UUID()
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: albumID, name: "Cyberpunk", createdAt: Date(),
            aiProfile: AlbumAIProfile(text: "Neon cities", builtAt: Date(), memberCount: 5)))
        try commitItem(1, prompt: "member prompt", albumIDs: [albumID.uuidString], in: dir)
        try commitItem(2, prompt: "neon alley", in: dir)       // unsorted candidate
        try commitItem(3, prompt: nil, in: dir)                 // promptless

        let stub = StubClassifier { _, _ in
            #"{"items":[{"id":2,"albums":[{"n":1,"c":0.9}]}]}"#
        }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        #expect(svc.phase == .review)
        #expect(svc.groups.map(\.id) == ["album:\(albumID.uuidString)", "promptless"])
        #expect(svc.groups[0].entries.map(\.itemID) == [2])
        #expect(svc.groups[1].entries.map(\.itemID) == [3])
    }

    @MainActor
    @Test func staleProfileIsBuiltAndConfirmedBeforeClassification() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)

        let albumID = UUID()   // no profile yet → stale
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: albumID, name: "Cyberpunk", createdAt: Date()))
        try commitItem(1, prompt: "member neon prompt", albumIDs: [albumID.uuidString], in: dir)
        try commitItem(2, prompt: "neon alley", in: dir)

        let stub = StubClassifier { system, _ in
            if system.contains("\"profile\"") {
                return #"{"profile":"Neon cityscapes"}"#
            }
            return #"{"items":[{"id":2,"albums":[{"n":1,"c":0.8}]}]}"#
        }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        #expect(svc.phase == .profilesReady)
        #expect(svc.builtProfiles.map(\.text) == ["Neon cityscapes"])

        await svc.confirmProfiles()
        #expect(svc.phase == .review)
        // Profile persisted to the album file with the membership baseline.
        let file = try #require(LibraryAlbumStore(itemsDirectory: dir).read(id: albumID))
        #expect(file.aiProfile?.text == "Neon cityscapes")
        #expect(file.aiProfile?.memberCount == 1)
        #expect(svc.groups.first?.entries.map(\.itemID) == [2])
    }

    @MainActor
    @Test func failedBatchesAreCountedAndOthersSurvive() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)

        let albumID = UUID()
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: albumID, name: "A", createdAt: Date(),
            aiProfile: AlbumAIProfile(text: "a", builtAt: Date(), memberCount: 99)))
        // 26 candidates → 2 batches at classifyBatchSize 25.
        for id in 1...26 { try commitItem(id, prompt: "prompt \(id)", in: dir) }

        let stub = StubClassifier { _, user in
            if user.contains("id 1:") {     // first batch fails
                throw OpenRouterError.badStatus(500)
            }
            return #"{"items":[{"id":26,"albums":[{"n":1,"c":0.9}]}]}"#
        }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        #expect(svc.phase == .review)
        #expect(svc.failedBatchCount == 1)
        #expect(svc.groups.contains { $0.id == "album:\(albumID.uuidString)" })
    }

    @MainActor
    @Test func allBatchesFailingReportsFailure() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try makeContainer()
        let albumService = makeAlbumService(container, dir: dir)
        try LibraryAlbumStore(itemsDirectory: dir).write(LibraryAlbumFile(
            id: UUID(), name: "A", createdAt: Date(),
            aiProfile: AlbumAIProfile(text: "a", builtAt: Date(), memberCount: 99)))
        try commitItem(1, prompt: "p", in: dir)

        let stub = StubClassifier { _, _ in throw OpenRouterError.badStatus(401) }
        let svc = SortAssistantService(albumService: albumService, classifier: stub, itemsDirectory: dir)
        await svc.run()

        guard case .failed = svc.phase else {
            Issue.record("expected .failed, got \(svc.phase)")
            return
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:DiffuselyTests/SortAssistantServiceTests -quiet`
Expected: compile error — `SortAssistantService` not defined.

- [ ] **Step 3: Implement**

Create `Diffusely/Services/Library/SortAssistant/SortAssistantService.swift`:

```swift
import Foundation

/// Orchestrates a Sort Assistant run: scan container → build stale album
/// profiles (pausing for user confirmation when any were built) → classify
/// unsorted prompts in batches → review groups. `@MainActor` so SwiftUI can
/// observe progress (mirrors `LibraryDateBackfillService`); blocking file I/O
/// is delegated to the scanner (detached) and the state queue (serial,
/// grey-spinner rule). Results live in memory only — a run is cheap to redo.
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

    func start() {
        guard runTask == nil, phase == .idle else { return }
        runTask = Task { await run() }
    }

    func beginClassification() {
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

    // MARK: - State queue

    private static func onStateQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            stateQueue.async { cont.resume(returning: work()) }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/SortAssistant/SortAssistantService.swift DiffuselyTests/SortAssistantServiceTests.swift
git commit -m "Add SortAssistantService run orchestration"
```

---

### Task 10: Accept path

**Files:**
- Modify: `Diffusely/Services/Library/SortAssistant/SortAssistantService.swift`
- Test: `DiffuselyTests/SortAssistantServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SortAssistantServiceTests`:

```swift
@MainActor
@Test func acceptAddsMembershipAndRecordsRejections() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let container = try makeContainer()
    let index = LibraryIndexService(modelContainer: container)
    let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })

    let albumID = await albumService.createAlbum(name: "Cyberpunk")
    try commitItem(1, prompt: "p1", in: dir)
    try commitItem(2, prompt: "p2", in: dir)
    await index.reconcile(itemsDirectory: dir)

    let svc = SortAssistantService(
        albumService: albumService,
        classifier: StubClassifier { _, _ in "" },
        itemsDirectory: dir)
    let group = SortAssistant.ReviewGroup(
        id: "album:\(albumID.uuidString)",
        kind: .album(id: albumID, name: "Cyberpunk"),
        entries: [.init(itemID: 1, confidence: 0.9), .init(itemID: 2, confidence: 0.8)])

    await svc.accept(group: group, selectedIDs: [1])   // 2 deselected → rejected

    let writer = LibraryFileWriter(itemsDirectory: dir)
    #expect(writer.readMetadata(itemID: 1)?.albumIDs == [albumID.uuidString])
    #expect(writer.readMetadata(itemID: 2)?.albumIDs == [])
    let state = SortAssistantStateStore(itemsDirectory: dir).read()
    #expect(state.isRejected(itemID: 2, albumID: albumID))
    #expect(!state.isRejected(itemID: 1, albumID: albumID))
}

@MainActor
@Test func acceptNewAlbumCreatesAlbumFirst() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let container = try makeContainer()
    let index = LibraryIndexService(modelContainer: container)
    let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })
    try commitItem(1, prompt: "p1", in: dir)
    try commitItem(2, prompt: "p2", in: dir)
    await index.reconcile(itemsDirectory: dir)

    let svc = SortAssistantService(
        albumService: albumService,
        classifier: StubClassifier { _, _ in "" },
        itemsDirectory: dir)
    let group = SortAssistant.ReviewGroup(
        id: "new:watercolor", kind: .newAlbum(name: "Watercolor"),
        entries: [.init(itemID: 1, confidence: 1), .init(itemID: 2, confidence: 1)])

    await svc.accept(group: group, selectedIDs: [1])

    let albums = try ModelContext(container).fetch(FetchDescriptor<PersistedAlbum>())
    let created = try #require(albums.first)
    #expect(created.name == "Watercolor")
    let writer = LibraryFileWriter(itemsDirectory: dir)
    #expect(writer.readMetadata(itemID: 1)?.albumIDs == [created.id.uuidString])
    #expect(SortAssistantStateStore(itemsDirectory: dir).read().isNewAlbumRejected(itemID: 2))
}

@MainActor
@Test func acceptForDeletedAlbumIsDropped() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let container = try makeContainer()
    let index = LibraryIndexService(modelContainer: container)
    let albumService = LibraryAlbumService(index: index, itemsDirectory: { dir })
    try commitItem(1, prompt: "p1", in: dir)
    await index.reconcile(itemsDirectory: dir)

    let svc = SortAssistantService(
        albumService: albumService,
        classifier: StubClassifier { _, _ in "" },
        itemsDirectory: dir)
    let ghost = UUID()   // album never created / deleted since classify
    let group = SortAssistant.ReviewGroup(
        id: "album:\(ghost.uuidString)", kind: .album(id: ghost, name: "Ghost"),
        entries: [.init(itemID: 1, confidence: 0.9)])

    await svc.accept(group: group, selectedIDs: [1])
    #expect(LibraryFileWriter(itemsDirectory: dir).readMetadata(itemID: 1)?.albumIDs == [])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test ... -only-testing:DiffuselyTests/SortAssistantServiceTests -quiet`
Expected: compile error — `accept(group:selectedIDs:)` not defined.

- [ ] **Step 3: Implement**

Add to `SortAssistantService`:

```swift
    // MARK: - Accept

    /// Applies the user's review of one group: adds membership for the
    /// selected ids (through the existing LibraryAlbumService write path),
    /// records rejections for the deselected ids, persists the state file,
    /// and removes the group from the pending list. For a new-album group the
    /// album is created first. A group for an album deleted since classify is
    /// dropped (no membership written).
    func accept(group: SortAssistant.ReviewGroup, selectedIDs: Set<Int>) async {
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2. Expected: PASS (all `SortAssistantServiceTests`).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Sort Assistant accept path: membership writes and rejection recording"
```

---

### Task 11: Settings — OpenRouter section

**Files:**
- Modify: `Diffusely/Views/SettingsView.swift`

No unit tests (the repo doesn't test SwiftUI views); verify by build + manual check in Task 14.

- [ ] **Step 1: Add the section**

Read `Diffusely/Views/SettingsView.swift`. Add these properties next to the existing `apiKeyManager` ones:

```swift
@StateObject private var openRouterConfig = OpenRouterConfig.shared
@State private var openRouterKeyInput = ""
```

Add this computed property, and place `sortAssistantSection` in the body's `Form`/`List` immediately after the existing Civitai API-key section:

```swift
private var sortAssistantSection: some View {
    Section {
        if openRouterConfig.hasAPIKey {
            HStack {
                Text("OpenRouter API Key")
                Spacer()
                Text("••••••••").foregroundColor(.secondary)
            }
            Button("Remove OpenRouter Key", role: .destructive) {
                openRouterConfig.apiKey = nil
                openRouterKeyInput = ""
            }
        } else {
            SecureField("OpenRouter API Key", text: $openRouterKeyInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save Key") {
                openRouterConfig.apiKey = openRouterKeyInput
            }
            .disabled(openRouterKeyInput.isEmpty)
        }
        TextField("Model", text: $openRouterConfig.model)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    } header: {
        Text("Sort Assistant")
    } footer: {
        Text("The Sort Assistant sends Library item prompts (text only, never images) to this OpenRouter model to suggest albums.")
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/SettingsView.swift
git commit -m "Add OpenRouter key/model settings for the Sort Assistant"
```

---

### Task 12: Sort Assistant sheet UI

**Files:**
- Create: `Diffusely/Views/SortAssistantSheet.swift`
- Create: `Diffusely/Views/SortReviewGroupView.swift`

No unit tests (SwiftUI views); verified by build + manual run in Task 14.

- [ ] **Step 1: Create `Diffusely/Views/SortAssistantSheet.swift`**

```swift
import SwiftUI

/// Sort Assistant flow: classify unsorted Library items with an LLM, then
/// review suggestions grouped by album. Presented from the Library's Albums
/// mode. Owns the service; the inner flow view observes it.
struct SortAssistantSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var openRouterConfig = OpenRouterConfig.shared
    @State private var service: SortAssistantService?

    var body: some View {
        NavigationStack {
            Group {
                if !openRouterConfig.hasAPIKey {
                    ContentUnavailableView(
                        "OpenRouter Key Needed",
                        systemImage: "key",
                        description: Text("Add your OpenRouter API key in Settings to use the Sort Assistant."))
                } else if let service {
                    SortAssistantFlowView(service: service)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Sort Assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        service?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            guard service == nil, openRouterConfig.hasAPIKey else { return }
            guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
            let classifier = OpenRouterClassifier(
                apiKey: openRouterConfig.apiKey ?? "",
                model: openRouterConfig.model)
            let svc = SortAssistantService(
                albumService: store.albumService,
                classifier: classifier,
                itemsDirectory: dir)
            service = svc
            svc.start()
        }
    }
}

/// Observes the service and renders the current phase.
private struct SortAssistantFlowView: View {
    @ObservedObject var service: SortAssistantService

    var body: some View {
        switch service.phase {
        case .idle, .scanning:
            ProgressView("Scanning library…")
        case .buildingProfiles(let done, let total):
            progress("Building album profiles…", done: done, total: total)
        case .profilesReady:
            profileConfirmation
        case .classifying(let done, let total):
            VStack(spacing: 16) {
                progress("Classifying prompts…", done: done, total: total)
                Button("Stop and review what's done") { service.cancel() }
                    .buttonStyle(.bordered)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Sort Failed", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .review:
            reviewList
        }
    }

    private func progress(_ label: String, done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(maxWidth: 280)
            Text("\(label) \(done)/\(total)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    /// Built profiles, editable before classification starts.
    private var profileConfirmation: some View {
        Form {
            Section {
                Text("The assistant summarized what each album contains, based on the prompts of items you've already filed. Edit anything that's off — these descriptions steer the sorting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach($service.builtProfiles) { $profile in
                Section(profile.name) {
                    TextEditor(text: $profile.text)
                        .frame(minHeight: 80)
                }
            }
            Section {
                Button("Continue") { service.beginClassification() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var reviewList: some View {
        List {
            if service.failedBatchCount > 0 {
                Section {
                    Label("\(service.failedBatchCount) request batch(es) failed — re-run later to cover those items.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if service.groups.isEmpty {
                ContentUnavailableView(
                    "All Reviewed", systemImage: "checkmark.circle",
                    description: Text("No suggestions left to review."))
            } else {
                Section("Suggestions") {
                    ForEach(service.groups) { group in
                        NavigationLink {
                            SortReviewGroupView(group: group, service: service)
                        } label: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text("\(group.entries.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Create `Diffusely/Views/SortReviewGroupView.swift`**

```swift
import SwiftUI
import SwiftData

/// One review group: a grid of suggested items (confidence-ordered, all
/// pre-selected). Deselect the misses, Accept writes membership and records
/// rejections. Long-press opens the full Manage Albums sheet for an item.
struct SortReviewGroupView: View {
    let group: SortAssistant.ReviewGroup
    @ObservedObject var service: SortAssistantService
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: Set<Int> = []
    @State private var itemsByID: [Int: PersistedLibraryItem] = [:]
    @State private var isAccepting = false
    @State private var manageRequest: LibraryView.AddToAlbumRequest?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    /// Unmatched / Couldn't-classify groups are informational only.
    private var isActionable: Bool {
        switch group.kind {
        case .album, .newAlbum: return true
        case .unmatched, .promptless: return false
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(group.entries, id: \.itemID) { entry in
                    if let item = itemsByID[entry.itemID] {
                        tile(for: item)
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(group.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isActionable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Accept (\(selectedIDs.count))") {
                        isAccepting = true
                        Task {
                            await service.accept(group: group, selectedIDs: selectedIDs)
                            store.notifyAlbumsChanged()
                            dismiss()
                        }
                    }
                    .disabled(isAccepting)
                }
            }
        }
        .sheet(item: $manageRequest) { request in
            ManageAlbumsSheet(
                itemIDs: request.itemIDs,
                summaries: LibrarySortService(modelContext: modelContext).albumSummaries(),
                membershipCounts: request.membershipCounts,
                onChanged: {})
                .environmentObject(store)
        }
        .task {
            selectedIDs = Set(group.entries.map(\.itemID))
            let ids = Set(group.entries.map(\.itemID))
            let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
            itemsByID = Dictionary(
                all.filter { ids.contains($0.itemID) }.map { ($0.itemID, $0) },
                uniquingKeysWith: { a, _ in a })
        }
    }

    private func tile(for item: PersistedLibraryItem) -> some View {
        let isSelected = selectedIDs.contains(item.itemID)
        return Color(.secondarySystemBackground)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                LibraryAsyncImage(
                    itemID: item.itemID,
                    mediaFileName: item.mediaFileName,
                    isVideo: item.isVideo,
                    maxDimension: LibraryImageRequest.gridDimension,
                    contentMode: .fill)
            }
            .clipped()
            .overlay {
                if isActionable && !isSelected {
                    Color.black.opacity(0.35)   // dim the deselected
                }
            }
            .overlay(alignment: .topTrailing) {
                if isActionable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isActionable else { return }
                if isSelected {
                    selectedIDs.remove(item.itemID)
                } else {
                    selectedIDs.insert(item.itemID)
                }
            }
            .onLongPressGesture {
                manageRequest = LibraryView.AddToAlbumRequest(
                    itemIDs: [item.itemID],
                    membershipCounts: LibrarySortService(modelContext: modelContext)
                        .albumMembershipCounts(for: [item.itemID]))
            }
    }
}
```

Note: `LibraryView.AddToAlbumRequest` is the existing identity-carrying sheet payload nested in `LibraryView` ([LibraryView.swift:46]). If the compiler complains about its access level, it's already internal — no change needed.

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/SortAssistantSheet.swift Diffusely/Views/SortReviewGroupView.swift
git commit -m "Add Sort Assistant sheet: profile confirmation, progress, grouped review"
```

---

### Task 13: Entry point in the Library's Albums mode

**Files:**
- Modify: `Diffusely/Views/LibraryView.swift`

- [ ] **Step 1: Add state and sheet**

In `LibraryView`, add near the other `@State` properties:

```swift
@State private var showingSortAssistant = false
```

In `body`, chain after the existing `.sheet(item: $addToAlbumRequest) { … }` modifier:

```swift
.sheet(isPresented: $showingSortAssistant) {
    SortAssistantSheet()
        .environmentObject(store)
}
```

(`reloadContent()` already fires via `store.albumsVersion` when accepts call `notifyAlbumsChanged()`, so no extra refresh wiring is needed.)

- [ ] **Step 2: Add the toolbar button**

In `libraryToolbar`'s non-selecting branch (the `else` block), after the mode-picker `ToolbarItem` (the one shown only for `filter == .all`), add:

```swift
if filter == .all && mode == .albums {
    ToolbarItem(placement: .primaryAction) {
        Button {
            showingSortAssistant = true
        } label: {
            Label("Sort Assistant", systemImage: "sparkles")
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/LibraryView.swift
git commit -m "Add Sort Assistant entry point to the Library Albums toolbar"
```

---

### Task 14: Full suite + manual verification

- [ ] **Step 1: Run the entire test suite**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
Expected: PASS — zero failures across all suites (the album-file schema change and `upsertAlbum` signature change touch many existing suites; this is the regression gate).

- [ ] **Step 2: Manual verification checklist (simulator or device)**

1. Settings → Sort Assistant: save an OpenRouter key; model field shows the default slug. **Verify the DeepSeek V4 slug against https://openrouter.ai/models and correct `OpenRouterConfig.defaultModel` if needed.**
2. Library → Albums → sparkles button opens the sheet.
3. Without a key: sheet shows "OpenRouter Key Needed".
4. With a key and items: profiles build for albums that have members (first run), confirmation list appears, Continue starts classification with batch progress.
5. Review: groups sorted largest-first; tapping a group shows the confidence-ordered grid pre-selected; deselect one item; Accept.
6. Back in Albums: accepted items appear in the album (grid reloads via `albumsVersion`).
7. Re-run the assistant: the deselected item is NOT re-suggested for that album (rejection memory).
8. "Stop and review what's done" mid-classification lands on a partial review list.

- [ ] **Step 3: Commit any fixes, then final commit**

```bash
git add -A
git commit -m "Sort Assistant: full-suite fixes after integration"
```

---

## Self-review notes (already applied)

- **Spec coverage:** album-file fields (T1/T2), rejection state file (T3), OpenRouter service + settings (T4/T11), profile phase incl. confirmation/editing (T6/T9/T12), batched classification with concurrency + partial failure + cancellation (T9), review groups incl. new-album / unmatched / couldn't-classify (T7/T12), accept through `LibraryAlbumService` with new-album creation ordering and deleted-album drop (T10), entry point (T13), testing list from the spec mapped across T1–T10.
- **Type consistency:** `AlbumAIProfile{text,builtAt,memberCount}`, `SortAssistant.{AlbumContext,Candidate,Suggestion,NewAlbumProposal,BatchOutcome,ReviewGroup}`, `SortAssistantService.{Phase,BuiltProfile,run,confirmProfiles,beginClassification,accept,cancel}` used identically across tasks.
- **Known judgment calls:** profile staleness baseline counts prompt-bearing members; rejected pairs vanish rather than reappearing in Unmatched; state-file reads happen once per run (cross-device write races on the rejection file resolve as last-writer-wins, acceptable for advisory data).
