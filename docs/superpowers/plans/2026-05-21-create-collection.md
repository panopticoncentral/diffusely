# Create a New Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users create a new photo/video ("Image") or post ("Post") collection from the collections list via a "+" toolbar button and a form sheet.

**Architecture:** A new `CreateCollectionView` form sheet collects name/type/description/privacy and calls a new `CivitaiService.createCollection` method, which POSTs to the authenticated `collection.upsert` tRPC endpoint. On success the sheet dismisses and `CollectionsView` triggers its existing `forceListRefresh()` to pull the new collection into the grid.

**Tech Stack:** SwiftUI (multiplatform iOS + macOS), SwiftData, Swift Testing (`import Testing`), tRPC-over-HTTP against the Civitai API.

---

## Notes for the implementer

- **No `.pbxproj` edits needed.** The Xcode project uses file-system-synchronized groups (`PBXFileSystemSynchronizedRootGroup`). New `.swift` files added under `Diffusely/Views/` and `DiffuselyTests/` are compiled automatically — do not hand-edit `Diffusely.xcodeproj/project.pbxproj`.
- **Build/test command (macOS, fastest — no simulator):**
  ```bash
  xcodebuild -scheme Diffusely -destination 'platform=macOS' build
  xcodebuild -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests test
  ```
  **Always pass `-only-testing:DiffuselyTests` when testing.** This runs only the unit-test bundle and skips the `DiffuselyUITests` UI-test target, which would otherwise launch the app via XCUITest and show the macOS "Automation running" overlay. The `CreateCollectionTests` added by this plan are plain unit tests and need nothing from the UI target.
  If macOS signing/SDK is unavailable, substitute an iOS Simulator destination, e.g. `-destination 'platform=iOS Simulator,name=iPhone 16'`.
- The pattern for authenticated write requests is `addImageToCollection` in `Diffusely/Services/CivitaiService.swift:622`. The pattern for parsing a tRPC batch response is `getAllUserCollections` in the same file (around line 482).
- Test harness for stubbed network: `StubURLProtocol` + `CivitaiService(session:)` in `DiffuselyTests/CollectionListFetchTests.swift`.

---

## Task 1: `makeUpsertBody` payload helper (TDD)

Builds the tRPC request body for `collection.upsert`. Pure function — no network, no API key — so it is fully unit-testable.

**Files:**
- Modify: `Diffusely/Services/CivitaiService.swift` (add a `static func` to the `CivitaiService` class)
- Test: `DiffuselyTests/CreateCollectionTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/CreateCollectionTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

struct CreateCollectionTests {

    /// Pulls the inner `{ name, type, description?, read }` json object out of
    /// the tRPC batch envelope produced by makeUpsertBody.
    private func innerJSON(_ body: [String: Any]) throws -> [String: Any] {
        let zero = try #require(body["0"] as? [String: Any])
        return try #require(zero["json"] as? [String: Any])
    }

    @Test func imageCollectionPayload() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "My Pics", type: "Image", description: "best of", read: "Private"
        )
        let json = try innerJSON(body)
        #expect(json["name"] as? String == "My Pics")
        #expect(json["type"] as? String == "Image")
        #expect(json["description"] as? String == "best of")
        #expect(json["read"] as? String == "Private")
    }

    @Test func postCollectionPublicPayload() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "My Posts", type: "Post", description: nil, read: "Public"
        )
        let json = try innerJSON(body)
        #expect(json["name"] as? String == "My Posts")
        #expect(json["type"] as? String == "Post")
        #expect(json["read"] as? String == "Public")
        // description omitted when nil
        #expect(json["description"] == nil)
    }

    @Test func emptyDescriptionOmitted() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "X", type: "Image", description: "   ", read: "Unlisted")
        let json = try innerJSON(body)
        #expect(json["description"] == nil)
        #expect(json["read"] as? String == "Unlisted")
    }

    /// The body must serialize cleanly to JSON (it is passed to JSONSerialization).
    @Test func payloadIsSerializable() throws {
        let body = CivitaiService.makeUpsertBody(
            name: "X", type: "Post", description: "y", read: "Private")
        let data = try JSONSerialization.data(withJSONObject: body)
        #expect(!data.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' test`
Expected: Compile failure — `CivitaiService.makeUpsertBody` does not exist.

- [ ] **Step 3: Add the helper**

In `Diffusely/Services/CivitaiService.swift`, add this static method inside the `CivitaiService` class (place it just above `addImageToCollection`):

```swift
/// Builds the tRPC request body for `collection.upsert`. Pure/testable.
/// A trimmed-empty or nil `description` is omitted from the payload.
static func makeUpsertBody(
    name: String,
    type: String,
    description: String?,
    read: String
) -> [String: Any] {
    var json: [String: Any] = [
        "name": name,
        "type": type,
        "read": read
    ]
    if let description = description,
       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        json["description"] = description
    }
    return ["0": ["json": json]]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' test`
Expected: PASS (all four `CreateCollectionTests` cases).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/CivitaiService.swift DiffuselyTests/CreateCollectionTests.swift
git commit -m "Add makeUpsertBody helper for collection.upsert payload"
```

---

## Task 2: `createCollection` service method

POSTs the upsert payload with Bearer auth and returns the new collection id.

**Files:**
- Modify: `Diffusely/Services/CivitaiService.swift` (add method directly below `makeUpsertBody`)

- [ ] **Step 1: Add the method**

In `Diffusely/Services/CivitaiService.swift`, add below `makeUpsertBody`:

```swift
/// Creates a new collection via `collection.upsert`. Returns the new
/// collection's id. Requires an API key.
/// - Parameters:
///   - type: "Image" or "Post".
///   - read: "Private", "Public", or "Unlisted".
func createCollection(
    name: String,
    type: String,
    description: String?,
    read: String
) async throws -> Int {
    let url = URL(string: "\(baseURL)/collection.upsert?batch=1")!

    let bodyData = try JSONSerialization.data(
        withJSONObject: CivitaiService.makeUpsertBody(
            name: name, type: type, description: description, read: read))

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    guard let apiKey = APIKeyManager.shared.apiKey else {
        throw URLError(.userAuthenticationRequired)
    }
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }

    struct UpsertResponse: Decodable {
        let result: UpsertResult
    }
    struct UpsertResult: Decodable {
        let data: UpsertData
    }
    struct UpsertData: Decodable {
        let json: UpsertCollection
    }
    struct UpsertCollection: Decodable {
        let id: Int
    }

    let decoded = try JSONDecoder().decode([UpsertResponse].self, from: data)
    guard let id = decoded.first?.result.data.json.id else {
        throw URLError(.cannotParseResponse)
    }
    return id
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. (`baseURL` and `session` are existing members of `CivitaiService`; the nested response structs mirror `getAllUserCollections`.)

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Services/CivitaiService.swift
git commit -m "Add createCollection service method (collection.upsert)"
```

---

## Task 3: `CreateCollectionView` form sheet

The form that collects input and performs the create.

**Files:**
- Create: `Diffusely/Views/CreateCollectionView.swift`

- [ ] **Step 1: Create the view**

Create `Diffusely/Views/CreateCollectionView.swift`:

```swift
import SwiftUI

/// Sheet for creating a new Image ("Photo / Video") or Post collection.
struct CreateCollectionView: View {
    /// Called after a collection is successfully created (passes the new id).
    /// The parent uses this to refresh its list.
    let onCreated: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()

    private enum CollectionTypeChoice: String, CaseIterable, Identifiable {
        case image = "Image"
        case post = "Post"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .image: return "Photo / Video"
            case .post: return "Post"
            }
        }
    }

    private enum Privacy: String, CaseIterable, Identifiable {
        case `private` = "Private"
        case unlisted = "Unlisted"
        case `public` = "Public"
        var id: String { rawValue }
        var label: String { rawValue }
    }

    @State private var type: CollectionTypeChoice = .image
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var privacy: Privacy = .private
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let nameLimit = 30
    private let descriptionLimit = 300

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(CollectionTypeChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Name") {
                    TextField("Collection name", text: $name)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > nameLimit {
                                name = String(newValue.prefix(nameLimit))
                            }
                        }
                }

                Section("Description") {
                    TextField("Optional", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: description) { _, newValue in
                            if newValue.count > descriptionLimit {
                                description = String(newValue.prefix(descriptionLimit))
                            }
                        }
                }

                Section("Privacy") {
                    Picker("Privacy", selection: $privacy) {
                        ForEach(Privacy.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("New Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
            .alert("Couldn't Create Collection",
                   isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 460)
        #endif
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let id = try await civitaiService.createCollection(
                name: trimmedName,
                type: type.rawValue,
                description: description,
                read: privacy.rawValue
            )
            onCreated(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/CreateCollectionView.swift
git commit -m "Add CreateCollectionView form sheet"
```

---

## Task 4: Wire the "+" button into `CollectionsView`

Adds the toolbar button and sheet, refreshing the list on success.

**Files:**
- Modify: `Diffusely/Views/CollectionsView.swift`

- [ ] **Step 1: Add sheet-presentation state**

In `Diffusely/Views/CollectionsView.swift`, add a state property next to the existing `@State private var showingSettings = false` (around line 10):

```swift
    @State private var showingCreateCollection = false
```

- [ ] **Step 2: Add the create sheet**

Immediately after the existing settings sheet modifier (`.sheet(isPresented: $showingSettings) { SettingsView() }`, around line 147-149), add:

```swift
            .sheet(isPresented: $showingCreateCollection) {
                CreateCollectionView { _ in
                    forceListRefresh()
                }
            }
```

- [ ] **Step 3: Add the "+" toolbar button**

In the `.toolbar { ... }` block (around line 150), inside the existing `if apiKeyManager.hasAPIKey {` branch, add a new toolbar item *before* the existing Refresh `ToolbarItem`:

```swift
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreateCollection = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                        .keyboardShortcut("n")  // ⌘N
                        .help("Create a new collection")
                    }
```

- [ ] **Step 4: Verify it builds**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -scheme Diffusely -destination 'platform=macOS' test`
Expected: PASS (existing tests + `CreateCollectionTests`).

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Views/CollectionsView.swift
git commit -m "Add New Collection button to collections list"
```

---

## Task 5: Manual verification

Network round-trips are not unit-tested (consistent with the other write methods), so verify by hand.

- [ ] **Step 1: Run the app** (iOS Simulator or Mac) with a valid Civitai API key configured in Settings.
- [ ] **Step 2:** On the Collections tab, tap the **"+"** button. Confirm the sheet shows Type (Photo / Video | Post), Name, Description, and Privacy.
- [ ] **Step 3:** Confirm **Create** is disabled until a name is entered, and that Name/Description stop accepting input at 30 / 300 chars.
- [ ] **Step 4:** Create an **Image** collection (Private). Confirm the sheet dismisses and the new collection appears in the grid after the refresh.
- [ ] **Step 5:** Create a **Post** collection (Public). Confirm it appears with the correct Post type badge.
- [ ] **Step 6:** (Optional) Verify on the Civitai website that both collections exist with the chosen name, type, and privacy.

---

## Self-Review Notes

- **Spec coverage:** Entry point (Task 4), full form name/type/description/privacy (Task 3), `createCollection` + `makeUpsertBody` (Tasks 1–2), stay-on-list refresh via `forceListRefresh` (Task 4), `makeUpsertBody` unit test (Task 1), manual network verification (Task 5). The spec's `.pbxproj` edit is intentionally omitted — synchronized groups make it unnecessary.
- **Type consistency:** `makeUpsertBody(name:type:description:read:)` and `createCollection(name:type:description:read:)` use identical parameter names/order across Tasks 1–3. `onCreated: (Int) -> Void` is defined in Task 3 and consumed in Task 4.
- **Privacy mapping:** UI `Privacy` enum raw values (`Private`/`Public`/`Unlisted`) are passed straight through as the API `read` value. `write` is never sent (server defaults to `Private`).
