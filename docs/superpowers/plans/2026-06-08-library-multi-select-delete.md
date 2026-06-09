# Library Multi-Select & Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user select multiple Library items via a toolbar "Select" button and delete them in one confirmed action, without leaving the Library grid.

**Architecture:** Selection is view state in `LibraryView` (`@State`, keyed by `itemID`). The testable deletion logic lives in `LibraryIndexService.remove(itemIDs:)` (batch index removal, single save) and a static file-deletion helper `LibraryStore.deleteItemFiles(itemIDs:in:)`. `LibraryStore.remove(itemIDs:)` resolves the items directory once, deletes files via the helper, removes index rows in one batch, and refreshes totals once. The existing single-item `remove(itemID:)` is refactored to share the same file helper.

**Tech Stack:** Swift, SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), Xcode project `Diffusely`.

---

## File Structure

- `Diffusely/Services/Library/LibraryIndexService.swift` — add `remove(itemIDs:)` batch index removal.
- `Diffusely/Services/Library/LibraryStore.swift` — add static `deleteItemFiles(itemIDs:in:)`, add `remove(itemIDs:)`, refactor `remove(itemID:)` to use the helper.
- `Diffusely/Views/LibraryView.swift` — selection state, selectable cell behavior, toolbar, confirmation dialog.
- `DiffuselyTests/LibraryTests.swift` — tests for batch index removal and the file-deletion helper.

## Test invocation reference

Run a single test suite from the repo root:

```bash
xcodebuild test -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DiffuselyTests/LibraryBatchRemovalTests 2>&1 | tail -20
```

Build the app (used as the verification step for view-only tasks):

```bash
xcodebuild build -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

---

## Task 1: Batch index removal in `LibraryIndexService`

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift` (add method after `remove(itemID:)` at line 54)
- Test: `DiffuselyTests/LibraryTests.swift` (add a new `@Suite`)

- [ ] **Step 1: Write the failing test**

Add this suite to the end of `DiffuselyTests/LibraryTests.swift`. It reuses the file's existing `makeMetadata` helper (defined at the top of the file).

```swift
@Suite struct LibraryBatchRemovalTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistedLibraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @Test func removeItemIDsDeletesListedRowsAndLeavesOthers() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)

        await index.ingest(metadata: makeMetadata(itemID: 1), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 2), downloadStatus: .downloaded)
        await index.ingest(metadata: makeMetadata(itemID: 3), downloadStatus: .downloaded)
        #expect(await index.itemCount() == 3)

        await index.remove(itemIDs: [1, 3])

        #expect(await index.itemCount() == 1)
        let items = try await MainActor.run {
            try container.mainContext.fetch(FetchDescriptor<PersistedLibraryItem>())
        }
        #expect(items.map(\.itemID) == [2])
    }

    @Test func removeItemIDsEmptyListIsNoOp() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.ingest(metadata: makeMetadata(itemID: 9), downloadStatus: .downloaded)

        await index.remove(itemIDs: [])

        #expect(await index.itemCount() == 1)
    }

    @Test func removeItemIDsIgnoresUnknownIDs() async throws {
        let container = try makeContainer()
        let index = LibraryIndexService(modelContainer: container)
        await index.ingest(metadata: makeMetadata(itemID: 1), downloadStatus: .downloaded)

        await index.remove(itemIDs: [1, 999])

        #expect(await index.itemCount() == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DiffuselyTests/LibraryBatchRemovalTests 2>&1 | tail -20
```

Expected: FAIL — compile error, `value of type 'LibraryIndexService' has no member 'remove(itemIDs:)'`.

- [ ] **Step 3: Write minimal implementation**

In `Diffusely/Services/Library/LibraryIndexService.swift`, add this method immediately after the existing `remove(itemID:)` method (after line 54):

```swift
    /// Batch-deletes index rows for the given ids in a single save. Used by the
    /// Library multi-select delete so removing N items is one persistence
    /// transaction instead of N. Unknown ids are skipped.
    func remove(itemIDs: [Int]) {
        guard !itemIDs.isEmpty else { return }
        var changed = false
        for itemID in itemIDs {
            if let existing = fetchItem(itemID: itemID) {
                modelContext.delete(existing)
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DiffuselyTests/LibraryBatchRemovalTests 2>&1 | tail -20
```

Expected: PASS — all three tests green.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift DiffuselyTests/LibraryTests.swift
git commit -m "Add batch LibraryIndexService.remove(itemIDs:) with single save"
```

---

## Task 2: File-deletion helper + batch `remove(itemIDs:)` on `LibraryStore`

**Files:**
- Modify: `Diffusely/Services/Library/LibraryStore.swift` (add static helper; add `remove(itemIDs:)`; refactor `remove(itemID:)` at lines 133-146)
- Test: `DiffuselyTests/LibraryTests.swift` (extend `LibraryBatchRemovalTests`)

- [ ] **Step 1: Write the failing test**

Add these two tests inside the existing `LibraryBatchRemovalTests` suite (from Task 1). They exercise the static file helper against a real temp directory — no iCloud container needed.

```swift
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor @Test func deleteItemFilesRemovesAllExtensionsForListedIDs() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Item 1: json + jpeg. Item 2: json + mp4. Item 3: untouched survivor.
        try Data("a".utf8).write(to: dir.appendingPathComponent("1.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("1.jpeg"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("2.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("2.mp4"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("3.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("3.jpeg"))

        LibraryStore.deleteItemFiles(itemIDs: [1, 2], in: dir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("2.json").path) == false)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("2.mp4").path) == false)
        // Survivor untouched.
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("3.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("3.jpeg").path))
    }

    @MainActor @Test func deleteItemFilesToleratesMissingFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Only the json exists; jpeg/mp4 absent. Must not throw.
        try Data("a".utf8).write(to: dir.appendingPathComponent("5.json"))

        LibraryStore.deleteItemFiles(itemIDs: [5], in: dir)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("5.json").path) == false)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DiffuselyTests/LibraryBatchRemovalTests 2>&1 | tail -20
```

Expected: FAIL — compile error, `type 'LibraryStore' has no member 'deleteItemFiles'`.

- [ ] **Step 3: Write minimal implementation**

In `Diffusely/Services/Library/LibraryStore.swift`, replace the existing `remove(itemID:)` method (lines 133-146):

```swift
    func remove(itemID: Int) async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        let coordinator = NSFileCoordinator()
        for name in ["\(itemID).json", "\(itemID).jpeg", "\(itemID).mp4"] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var err: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                try? FileManager.default.removeItem(at: u)
            }
        }
        await indexService.remove(itemID: itemID)
        await refreshTotals()
    }
```

with this — a shared static helper plus single- and batch-delete methods that both use it:

```swift
    /// Coordinates deletion of the on-disk files (`{id}.json` / `.jpeg` / `.mp4`)
    /// for the given ids. Static and directory-injected so it is unit-testable
    /// against a temp directory without the iCloud container. Missing files are
    /// skipped. Shared by `remove(itemID:)` and `remove(itemIDs:)`.
    static func deleteItemFiles(itemIDs: [Int], in dir: URL) {
        let coordinator = NSFileCoordinator()
        for itemID in itemIDs {
            for name in ["\(itemID).json", "\(itemID).jpeg", "\(itemID).mp4"] {
                let url = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                var err: NSError?
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
    }

    func remove(itemID: Int) async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        Self.deleteItemFiles(itemIDs: [itemID], in: dir)
        await indexService.remove(itemID: itemID)
        await refreshTotals()
    }

    /// Batch delete for the Library multi-select action. Resolves the items
    /// directory once, deletes all files, removes all index rows in a single
    /// save, then refreshes totals once — so removing N items is not N directory
    /// resolves and N totals refreshes.
    func remove(itemIDs: [Int]) async {
        guard !itemIDs.isEmpty else { return }
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        Self.deleteItemFiles(itemIDs: itemIDs, in: dir)
        await indexService.remove(itemIDs: itemIDs)
        await refreshTotals()
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:DiffuselyTests/LibraryBatchRemovalTests 2>&1 | tail -20
```

Expected: PASS — all five tests in the suite green.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryStore.swift DiffuselyTests/LibraryTests.swift
git commit -m "Add LibraryStore batch remove(itemIDs:) sharing a static file-delete helper"
```

---

## Task 3: Selection state and selectable cells in `LibraryView`

**Files:**
- Modify: `Diffusely/Views/LibraryView.swift` (state block ~lines 9-16; `cells(for:)` lines 111-121; add a selectable-thumbnail helper and toggle action)

This task is view code with no unit test (consistent with the rest of the view layer). Verification is a successful build; visual confirmation happens in Task 4 once the toolbar can enter selection mode.

- [ ] **Step 1: Add selection state**

In `Diffusely/Views/LibraryView.swift`, after the existing `@State private var didSeedGroups = false` line (line 16), add:

```swift
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showingBulkDeleteConfirm = false
```

- [ ] **Step 2: Make cells switch between navigate and select**

Replace the `cells(for:)` method (lines 111-121):

```swift
    @ViewBuilder
    private func cells(for items: [PersistedLibraryItem]) -> some View {
        ForEach(items) { item in
            NavigationLink {
                LibraryDetailView(itemID: item.itemID)
            } label: {
                thumbnail(for: item)
            }
            .buttonStyle(.plain)
        }
    }
```

with:

```swift
    @ViewBuilder
    private func cells(for items: [PersistedLibraryItem]) -> some View {
        ForEach(items) { item in
            if isSelecting {
                Button {
                    toggleSelection(item.itemID)
                } label: {
                    selectableThumbnail(for: item)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    LibraryDetailView(itemID: item.itemID)
                } label: {
                    thumbnail(for: item)
                }
                .buttonStyle(.plain)
            }
        }
    }
```

- [ ] **Step 3: Add the selectable-thumbnail wrapper and toggle action**

In `Diffusely/Views/LibraryView.swift`, add this method immediately after the existing `thumbnail(for:)` method (after line 235):

```swift
    /// The grid thumbnail decorated for selection mode: a check badge in the
    /// top-trailing corner and a slight dim when selected.
    private func selectableThumbnail(for item: PersistedLibraryItem) -> some View {
        let isSelected = selectedIDs.contains(item.itemID)
        return thumbnail(for: item)
            .overlay {
                if isSelected {
                    Color.black.opacity(0.25)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
            }
    }

    private func toggleSelection(_ itemID: Int) {
        if selectedIDs.contains(itemID) {
            selectedIDs.remove(itemID)
        } else {
            selectedIDs.insert(itemID)
        }
    }
```

- [ ] **Step 4: Verify it builds**

```bash
xcodebuild build -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. (Selection mode is not reachable from the UI yet — that arrives in Task 4. There should be no "unused" warnings because `isSelecting`/`selectedIDs` are now read by `cells(for:)`. `showingBulkDeleteConfirm` is wired in Task 4; an unused-warning on it here is acceptable.)

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Views/LibraryView.swift
git commit -m "Add Library selection state and selectable grid cells"
```

---

## Task 4: Toolbar, selection title, and confirmed bulk delete

**Files:**
- Modify: `Diffusely/Views/LibraryView.swift` (`body` toolbar/title lines 18-42; add helpers)

This is view wiring; verification is a build plus a manual run-through.

- [ ] **Step 1: Replace the navigation title and toolbar in `body`**

In `Diffusely/Views/LibraryView.swift`, replace the title + toolbar portion of `body` (lines 20-28):

```swift
            .navigationTitle("Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySortMenu(selectedSort: $selectedSort)
                }
            }
```

with:

```swift
            .navigationTitle(isSelecting ? selectionTitle : "Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") { exitSelection() }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            showingBulkDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        LibrarySortMenu(selectedSort: $selectedSort)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Select") { isSelecting = true }
                            .disabled(content.isEmpty)
                    }
                }
            }
            .confirmationDialog(
                bulkDeleteTitle,
                isPresented: $showingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = Array(selectedIDs)
                    Task {
                        await store.remove(itemIDs: ids)
                        exitSelection()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes your saved copies and their metadata from iCloud.")
            }
```

Note: `content.isEmpty` uses the existing `isEmpty` on `LibrarySortService.LibrarySortedContent` (already referenced at line 68).

- [ ] **Step 2: Add the title/dialog text helpers and the exit action**

In `Diffusely/Views/LibraryView.swift`, add these to the `// MARK: - Actions` section (e.g. after `toggle(_:)`, around line 337):

```swift
    private var selectionTitle: String {
        selectedIDs.isEmpty ? "Select Items" : "\(selectedIDs.count) Selected"
    }

    private var bulkDeleteTitle: String {
        let n = selectedIDs.count
        return "Delete \(n) item\(n == 1 ? "" : "s")?"
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }
```

- [ ] **Step 3: Verify it builds**

```bash
xcodebuild build -scheme Diffusely \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **` with no unused-variable warnings (`showingBulkDeleteConfirm` is now used by the dialog).

- [ ] **Step 4: Manual verification**

Launch the app in the simulator, open the Library tab (must have at least one saved item), then confirm:
- A "Select" button appears in the toolbar next to the sort menu.
- Tapping "Select" hides the sort menu, swaps the title to "Select Items", and shows "Done" + a disabled trash button.
- Tapping thumbnails toggles a check badge and dims the selected cells; the title updates to "N Selected" and the trash button enables.
- Tapping trash shows "Delete N items?" with the iCloud-copy message; "Delete" removes exactly the selected items and returns to normal (non-selecting) mode; "Cancel" leaves selection intact.
- The grid count footer updates after a delete.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Views/LibraryView.swift
git commit -m "Add Library multi-select toolbar, count title, and confirmed bulk delete"
```

---

## Self-Review Notes

- **Spec coverage:** Toolbar "Select" (Task 4), tap-to-toggle + check badge (Task 3), live "N Selected" title (Task 4), trash + confirmation-with-count (Task 4), `LibraryStore.remove(itemIDs:)` (Task 2), batch index removal with single save (Task 1), single `remove(itemID:)` retained for `LibraryDetailView` (Task 2, refactored to share the helper — behavior preserved). Grouped-view selection works because cells key off `itemID` regardless of grouping (no code change needed). Out-of-scope items (Select All, long-press, non-delete actions) are intentionally absent.
- **Type consistency:** `remove(itemIDs:)`, `deleteItemFiles(itemIDs:in:)`, `toggleSelection(_:)`, `exitSelection()`, `selectionTitle`, `bulkDeleteTitle`, `selectableThumbnail(for:)`, `selectedIDs`, `isSelecting`, `showingBulkDeleteConfirm` are named identically everywhere they appear.
- **No placeholders:** every code step shows complete code; every command shows expected output.
