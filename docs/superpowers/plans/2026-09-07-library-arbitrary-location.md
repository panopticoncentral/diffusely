# Open the Library at an Arbitrary Location (macOS) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user point Diffusely's personal Library at an arbitrary local folder instead of the iCloud container, so an exported folder opens in place, unencrypted.

**Architecture:** `LibraryContainer` — already the single seam every Library service resolves its directory through — becomes root-aware: it holds a `LibraryRoot` (`.iCloud` or `.custom(URL)`), a monotonic `rootGeneration`, and a `setRoot` that flips both. Capabilities that only make sense under iCloud (encryption, `NSMetadataQuery`, materialization, cache eviction) are read off the active root. A `LibraryRootCoordinator` orchestrates the hot-swap; the generation counter makes a late-finishing scan of the old root inert instead of destructive.

**Tech Stack:** Swift 6 / SwiftUI, SwiftData, XCTest, `DispatchSource` file-system events, `NSOpenPanel`.

**Spec:** `docs/superpowers/specs/2026-09-07-library-arbitrary-location-design.md`

## Global Constraints

- **macOS only.** All UI and the folder picker are inside `#if os(macOS)`. iOS keeps resolving the iCloud container exactly as today and must continue to build.
- **A custom root is unconditionally plaintext.** No `vault.json` is ever written or read outside the iCloud container.
- **A custom root is local storage.** Never provider-synced (OneDrive, Dropbox). Treated as always-local; no materialization story.
- **The chosen folder IS the items directory.** Flat `<id>.json` / `<id>.<ext>` / `album-<uuid>.json`. No `Items/` subfolder is created inside it.
- **A custom root is never created.** `createDirectory` must not run for `.custom`; absence is an error state.
- **Switching never moves data.** It re-points the app only.
- **No reconcile may run against a missing, switching, or stale root.**
- Existing tests must stay green. Run with `-parallel-testing-enabled NO` (parallel workers are flaky on this machine).

**Test commands** (used verbatim in the steps below):

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/SUITE 2>&1 | tail -20
```

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

The second is the iOS compile check — it needs no simulator device, which matters because devices come and go on this machine. Run it in any task that edits a file shared with iOS.

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `Diffusely/Services/Library/Root/LibraryRoot.swift` | The `LibraryRoot` enum, `LibraryRootError`, `LibraryRootCapabilities`. Pure values, no I/O. |
| `Diffusely/Services/Library/Root/LibraryRootStore.swift` | Persist / load the root; validate a candidate folder. |
| `Diffusely/Services/Library/Root/LibraryFolderWatcher.swift` | `DispatchSource` directory watcher for custom roots. |
| `Diffusely/Services/Library/Root/LibraryRootCoordinator.swift` | Orchestrates the switch sequence. |
| `Diffusely/Utilities/LibraryRootPanel.swift` | `NSOpenPanel` folder picker (macOS only). |
| `Diffusely/Views/LibraryRootGateViews.swift` | The `switchingRoot` and `rootUnavailable` gate views. |
| `Diffusely/Views/LibraryLocationRow.swift` | The Settings "Library Location" row. |

**Modify:**

| File | Change |
|---|---|
| `Diffusely/Services/Library/LibraryContainer.swift` | Root-aware resolution, `rootGeneration`, `setRoot`, `vaultURLs()` fails for `.custom`. |
| `Diffusely/Services/Library/LibraryIndexService.swift` | Generation-tagged scan application. |
| `Diffusely/Services/Library/LibraryVaultProvider.swift` | Two new gate cases, root override, plaintext-root bootstrap, `rebootstrap()`. |
| `Diffusely/Services/Library/LibraryStore.swift` | Change-detection selection, quiesce/restart, capability-aware status. |
| `Diffusely/Views/LibraryView.swift` | Two new gate cases in `gatedContent`. |
| `Diffusely/Views/SettingsView.swift` | Location row, encryption row disabled, cache controls hidden, new reason strings. |

**Test files:** `DiffuselyTests/LibraryRootTests.swift`, `LibraryRootStoreTests.swift`, `LibraryContainerRootTests.swift`, `LibraryIndexGenerationTests.swift`, `LibraryVaultProviderRootGateTests.swift`, `LibraryFolderWatcherTests.swift`, `LibraryRootCoordinatorTests.swift`, `LibraryRootUITextTests.swift`.

---

### Task 1: `LibraryRoot`, capabilities, and persistence

**Files:**
- Create: `Diffusely/Services/Library/Root/LibraryRoot.swift`
- Create: `Diffusely/Services/Library/Root/LibraryRootStore.swift`
- Test: `DiffuselyTests/LibraryRootTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum LibraryRoot { case iCloud; case custom(URL) }` with `var capabilities: LibraryRootCapabilities`; `struct LibraryRootCapabilities { allowsEncryption, usesMetadataQuery, supportsMaterialization, supportsCacheLimit: Bool }`; `enum LibraryRootError: Error, Equatable { case notADirectory, notWritable, encryptedLibrary, isICloudContainer, unavailable(URL) }`; `final class LibraryRootStore { init(defaults: UserDefaults); func load() -> LibraryRoot; func save(_ root: LibraryRoot); static let defaultsKey = "library_root_path" }`.

Persistence deliberately does **not** validate: a saved path that has since vanished must still load as `.custom(url)` so the `rootUnavailable` UI can name it. Validation is Task 2.

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryRootTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryRootTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "LibraryRootTests-\(UUID().uuidString)")!
        return suite
    }

    func testICloudCapabilities() {
        let caps = LibraryRoot.iCloud.capabilities
        XCTAssertTrue(caps.allowsEncryption)
        XCTAssertTrue(caps.usesMetadataQuery)
        XCTAssertTrue(caps.supportsMaterialization)
        XCTAssertTrue(caps.supportsCacheLimit)
    }

    func testCustomCapabilitiesAreAllOff() {
        let caps = LibraryRoot.custom(URL(fileURLWithPath: "/tmp/x")).capabilities
        XCTAssertFalse(caps.allowsEncryption)
        XCTAssertFalse(caps.usesMetadataQuery)
        XCTAssertFalse(caps.supportsMaterialization)
        XCTAssertFalse(caps.supportsCacheLimit)
    }

    func testLoadDefaultsToICloudWhenNothingStored() {
        let store = LibraryRootStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .iCloud)
    }

    func testCustomRootRoundTrips() {
        let store = LibraryRootStore(defaults: makeDefaults())
        let url = URL(fileURLWithPath: "/Volumes/Media/Diffusely Library")
        store.save(.custom(url))
        XCTAssertEqual(store.load(), .custom(url))
    }

    func testSavingICloudClearsAnyStoredPath() {
        let defaults = makeDefaults()
        let store = LibraryRootStore(defaults: defaults)
        store.save(.custom(URL(fileURLWithPath: "/tmp/lib")))
        store.save(.iCloud)
        XCTAssertEqual(store.load(), .iCloud)
        XCTAssertNil(defaults.string(forKey: LibraryRootStore.defaultsKey))
    }

    /// A stored root whose folder has since disappeared must still LOAD, so the
    /// blocked-state UI can name the missing path. Validation is a separate step.
    func testLoadDoesNotValidateThePath() {
        let store = LibraryRootStore(defaults: makeDefaults())
        let gone = URL(fileURLWithPath: "/Volumes/Unplugged/Library")
        store.save(.custom(gone))
        XCTAssertEqual(store.load(), .custom(gone))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootTests 2>&1 | tail -20
```

Expected: build failure — `cannot find 'LibraryRoot' in scope`.

- [ ] **Step 3: Write `LibraryRoot.swift`**

```swift
import Foundation

/// Where the personal Library lives.
///
/// `.iCloud` is the app's ubiquity container (with its Application Support
/// fallback when iCloud is off) — the only root that may be encrypted at rest.
/// `.custom` is a local folder the user chose, which IS the items directory:
/// flat `<id>.json` / `<id>.<ext>` / `album-<uuid>.json`, exactly the layout
/// `LibraryExporter` writes, so an export destination opens in place.
enum LibraryRoot: Equatable {
    case iCloud
    case custom(URL)

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var customURL: URL? {
        if case .custom(let url) = self { return url }
        return nil
    }

    var capabilities: LibraryRootCapabilities {
        switch self {
        case .iCloud:
            return LibraryRootCapabilities(
                allowsEncryption: true,
                usesMetadataQuery: true,
                supportsMaterialization: true,
                supportsCacheLimit: true
            )
        case .custom:
            // Encryption is an iCloud-only concern: a folder the user chose is
            // storage they control and can encrypt themselves. The other three
            // are all iCloud mechanisms with no local equivalent — and a cache
            // limit in particular would be a control that silently does nothing,
            // since `evictUbiquitousItem` is a no-op on a plain file.
            return LibraryRootCapabilities(
                allowsEncryption: false,
                usesMetadataQuery: false,
                supportsMaterialization: false,
                supportsCacheLimit: false
            )
        }
    }
}

struct LibraryRootCapabilities: Equatable {
    let allowsEncryption: Bool
    let usesMetadataQuery: Bool
    let supportsMaterialization: Bool
    let supportsCacheLimit: Bool
}

enum LibraryRootError: Error, Equatable {
    case notADirectory
    case notWritable
    case encryptedLibrary
    case isICloudContainer
    /// The saved custom root is not present right now (unplugged volume,
    /// renamed folder). Carries the path so the UI can name it.
    case unavailable(URL)

    var message: String {
        switch self {
        case .notADirectory:
            return "That isn't a folder Diffusely can open."
        case .notWritable:
            return "Diffusely can't write to that folder."
        case .encryptedLibrary:
            return "That folder holds an encrypted Library. Encrypted Libraries can only be opened in iCloud."
        case .isICloudContainer:
            return "That's Diffusely's own iCloud folder — choose iCloud Drive instead."
        case .unavailable(let url):
            return "Library not found at \(url.path)."
        }
    }
}
```

- [ ] **Step 4: Write `LibraryRootStore.swift`**

Validation lands here in Task 2; this step is persistence only.

```swift
import Foundation

/// Persists which `LibraryRoot` the app is using, and validates candidate
/// folders before a switch.
///
/// The stored form is a plain path, not a security-scoped bookmark: the Mac app
/// is unsandboxed (`Diffusely.entitlements` carries only iCloud keys — see
/// `LibraryExportPanel`), so a path is sufficient, and it is also what the
/// "Library not found" UI needs to show.
final class LibraryRootStore {
    static let defaultsKey = "library_root_path"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let standard = LibraryRootStore()

    /// Never validates: a root whose folder has vanished must still load so the
    /// blocked state can name the path instead of silently reverting to iCloud.
    func load() -> LibraryRoot {
        guard let path = defaults.string(forKey: Self.defaultsKey), !path.isEmpty else {
            return .iCloud
        }
        return .custom(URL(fileURLWithPath: path, isDirectory: true))
    }

    func save(_ root: LibraryRoot) {
        switch root {
        case .iCloud:
            defaults.removeObject(forKey: Self.defaultsKey)
        case .custom(let url):
            defaults.set(url.path, forKey: Self.defaultsKey)
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootTests 2>&1 | tail -20
```

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Verify iOS still builds**

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Services/Library/Root/LibraryRoot.swift Diffusely/Services/Library/Root/LibraryRootStore.swift DiffuselyTests/LibraryRootTests.swift
git commit -m "feat(library): add LibraryRoot, capabilities, and root persistence"
```

---

### Task 2: Validate a candidate folder

**Files:**
- Modify: `Diffusely/Services/Library/Root/LibraryRootStore.swift`
- Test: `DiffuselyTests/LibraryRootStoreTests.swift`

**Interfaces:**
- Consumes: `LibraryRoot`, `LibraryRootError` from Task 1.
- Produces: `func validate(_ url: URL, iCloudItemsDirectory: URL?) -> LibraryRootError?` on `LibraryRootStore` (`nil` means valid — `Result<Void, E>` is deliberately avoided because `Void` isn't `Equatable`, so it can't be asserted with `XCTAssertEqual`). `iCloudItemsDirectory` is injected rather than resolved internally, both because resolving it is blocking actor I/O and because tests must not touch the real container.

An **empty folder is valid** — that is how a fresh Library is started somewhere.

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryRootStoreTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryRootStoreTests: XCTestCase {
    private var tempRoot: URL!
    private let store = LibraryRootStore(defaults: UserDefaults(suiteName: "LibraryRootStoreTests")!)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRootStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, into folder: URL) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    func testEmptyFolderIsValid() throws {
        let folder = try makeFolder("empty")
        XCTAssertNil(store.validate(folder, iCloudItemsDirectory: nil))
    }

    func testFolderWithPlaintextLibraryIsValid() throws {
        let folder = try makeFolder("library")
        try write("12345.json", into: folder)
        try write("12345.jpeg", into: folder)
        try write("album-\(UUID().uuidString).json", into: folder)
        XCTAssertNil(store.validate(folder, iCloudItemsDirectory: nil))
    }

    func testMissingFolderIsNotADirectory() {
        let missing = tempRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(store.validate(missing, iCloudItemsDirectory: nil), .notADirectory)
    }

    func testFileIsNotADirectory() throws {
        try write("plain.txt", into: tempRoot)
        XCTAssertEqual(store.validate(tempRoot.appendingPathComponent("plain.txt"),
                                      iCloudItemsDirectory: nil), .notADirectory)
    }

    func testFolderWithVaultFileIsRejected() throws {
        let folder = try makeFolder("vaulted")
        try write("vault.json", into: folder)
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .encryptedLibrary)
    }

    func testFolderWithSealedFilesIsRejected() throws {
        for (name, ext) in [("meta", "m"), ("media", "b"), ("aux", "x")] {
            let folder = try makeFolder("sealed-\(name)")
            try write("a1b2c3.\(ext)", into: folder)
            XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .encryptedLibrary,
                           "a .\(ext) file should mark the folder encrypted")
        }
    }

    func testICloudContainerIsRejected() throws {
        let folder = try makeFolder("container")
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: folder), .isICloudContainer)
    }

    func testNotWritableFolderIsRejected() throws {
        let folder = try makeFolder("readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertEqual(store.validate(folder, iCloudItemsDirectory: nil), .notWritable)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootStoreTests 2>&1 | tail -20
```

Expected: build failure — no `validate` member.

- [ ] **Step 3: Implement `validate`**

Append to `LibraryRootStore`:

```swift
    /// Encrypted-container markers. `vault.json` is the vault file itself;
    /// `.m` / `.b` / `.x` are `LibraryFileCrypto`'s opaque sealed-file roles
    /// (meta / media / aux). Any of them means this folder is an encrypted
    /// Library, which only iCloud may hold — and refusing it here is what stops
    /// such a folder opening as a mysteriously empty Library.
    private static let vaultFileName = "vault.json"
    private static let sealedExtensions: Set<String> = ["m", "b", "x"]

    /// `iCloudItemsDirectory` is injected rather than resolved here: resolving
    /// it is blocking, actor-isolated I/O, and the test suite must never touch
    /// the real container. Pass `nil` when it is unknown or unavailable — the
    /// container check is simply skipped.
    func validate(_ url: URL, iCloudItemsDirectory: URL?) -> LibraryRootError? {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .notADirectory
        }

        if let iCloudItemsDirectory,
           url.standardizedFileURL == iCloudItemsDirectory.standardizedFileURL {
            return .isICloudContainer
        }

        guard fileManager.isWritableFile(atPath: url.path) else {
            return .notWritable
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        for name in contents {
            if name == Self.vaultFileName {
                return .encryptedLibrary
            }
            if Self.sealedExtensions.contains((name as NSString).pathExtension) {
                return .encryptedLibrary
            }
        }

        // An empty folder is deliberately valid: that is how a user starts a
        // fresh Library somewhere.
        return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootStoreTests 2>&1 | tail -20
```

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Root/LibraryRootStore.swift DiffuselyTests/LibraryRootStoreTests.swift
git commit -m "feat(library): validate a candidate Library folder"
```

---

### Task 3: Make `LibraryContainer` root-aware

**Files:**
- Modify: `Diffusely/Services/Library/LibraryContainer.swift`
- Test: `DiffuselyTests/LibraryContainerRootTests.swift`

**Interfaces:**
- Consumes: `LibraryRoot`, `LibraryRootError`, `LibraryRootStore` (Tasks 1–2).
- Produces: on `LibraryContainer` — `init(rootStore: LibraryRootStore)`, `var root: LibraryRoot`, `var rootGeneration: Int`, `var capabilities: LibraryRootCapabilities`, `@discardableResult func setRoot(_ root: LibraryRoot) -> Int`, and `func iCloudItemsDirectoryIfAvailable() -> URL?`. `itemsDirectory()` and `vaultURLs()` keep their signatures.

Three behaviours are load-bearing:

1. `.custom` **never creates** its directory. Today `itemsDirectory()` calls `createDirectory(withIntermediateDirectories: true)` unconditionally; against an unmounted volume that would create an empty folder at the mount point, which reconcile would then treat as an authoritative empty Library.
2. `vaultURLs()` **throws** for `.custom`. Its `deletingLastPathComponent()` derivation is correct for `Documents/Items/` and would otherwise resolve into the *parent* of the user's chosen folder.
3. `setRoot` bumps `rootGeneration` and clears the cached directory, so in-flight work can be recognised as stale (Task 4).

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryContainerRootTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryContainerRootTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryContainerRootTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeContainer() -> LibraryContainer {
        let defaults = UserDefaults(suiteName: "LibraryContainerRootTests-\(UUID().uuidString)")!
        return LibraryContainer(rootStore: LibraryRootStore(defaults: defaults))
    }

    func testCustomRootResolvesToTheChosenFolderItself() async throws {
        let container = makeContainer()
        await container.setRoot(.custom(tempRoot))
        let resolved = try await container.itemsDirectory()
        XCTAssertEqual(resolved.standardizedFileURL, tempRoot.standardizedFileURL)
    }

    /// The critical one: an unplugged volume must not have a Library folder
    /// conjured at its mount point, which reconcile would read as "empty".
    func testMissingCustomRootThrowsAndIsNotCreated() async {
        let container = makeContainer()
        let missing = tempRoot.appendingPathComponent("unplugged", isDirectory: true)
        await container.setRoot(.custom(missing))

        do {
            _ = try await container.itemsDirectory()
            XCTFail("expected itemsDirectory() to throw for a missing custom root")
        } catch let error as LibraryRootError {
            XCTAssertEqual(error, .unavailable(missing))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "a missing custom root must never be created")
    }

    func testVaultURLsThrowForACustomRoot() async {
        let container = makeContainer()
        await container.setRoot(.custom(tempRoot))
        do {
            _ = try await container.vaultURLs()
            XCTFail("expected vaultURLs() to throw for a custom root")
        } catch let error as LibraryRootError {
            XCTAssertEqual(error, .encryptedLibrary)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSetRootBumpsTheGeneration() async {
        let container = makeContainer()
        let first = await container.rootGeneration
        let second = await container.setRoot(.custom(tempRoot))
        XCTAssertGreaterThan(second, first)
        let third = await container.setRoot(.iCloud)
        XCTAssertGreaterThan(third, second)
    }

    func testSetRootClearsTheCachedDirectory() async throws {
        let container = makeContainer()
        let other = tempRoot.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        await container.setRoot(.custom(tempRoot))
        _ = try await container.itemsDirectory()
        await container.setRoot(.custom(other))
        let resolved = try await container.itemsDirectory()

        XCTAssertEqual(resolved.standardizedFileURL, other.standardizedFileURL)
    }

    func testCustomRootIsNotICloudBacked() async throws {
        let container = makeContainer()
        await container.setRoot(.custom(tempRoot))
        _ = try await container.itemsDirectory()
        let backed = await container.isICloudBacked
        XCTAssertFalse(backed)
    }

    func testRootIsRestoredFromPersistence() async {
        let defaults = UserDefaults(suiteName: "LibraryContainerRootTests-restore")!
        defaults.removePersistentDomain(forName: "LibraryContainerRootTests-restore")
        let rootStore = LibraryRootStore(defaults: defaults)
        rootStore.save(.custom(tempRoot))

        let container = LibraryContainer(rootStore: rootStore)
        let root = await container.root
        XCTAssertEqual(root, .custom(tempRoot))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryContainerRootTests 2>&1 | tail -20
```

Expected: build failure — no `init(rootStore:)`, no `setRoot`.

- [ ] **Step 3: Rewrite `LibraryContainer.swift`**

Replace the whole file. The iCloud branch, the local fallback and `migrateLocalItems` are unchanged in behaviour — they now simply live under `case .iCloud`.

```swift
import Foundation

/// Resolves the on-disk directory that backs the personal library.
///
/// The active `LibraryRoot` decides what that means:
///
/// - `.iCloud` — the app's ubiquity container (`Documents/Items`), falling back
///   to a local Application Support directory when iCloud is off, with local
///   items migrated in the next time the container becomes available. This is
///   the only root that may be encrypted at rest.
/// - `.custom` — a local folder the user chose, which IS the items directory.
///   Never created and never encrypted; if it isn't there, that's an error, not
///   something to repair (creating it would hand reconcile an empty directory
///   to treat as authoritative).
///
/// `url(forUbiquityContainerIdentifier:)` performs blocking I/O and returns
/// `nil` when iCloud is off, so resolution happens exactly once on a background
/// actor and the result is cached until the root changes.
actor LibraryContainer {
    static let shared = LibraryContainer(rootStore: .standard)

    static let containerIdentifier = "iCloud.AchatesSoftware.Diffusely"
    private static let itemsFolderName = "Items"

    private let rootStore: LibraryRootStore
    private(set) var root: LibraryRoot

    /// Monotonic counter bumped on every root change. Work started under an
    /// older generation — most importantly a container scan already running on
    /// `LibraryIndexService`'s own queue — is recognised as stale and discarded
    /// instead of being applied to the new root's index, where it would prune
    /// every row it never saw. Cancelling triggers cannot stop a scan already
    /// in flight; this can.
    private(set) var rootGeneration = 0

    private var cachedItemsDirectory: URL?
    private var resolvedICloud = false

    init(rootStore: LibraryRootStore) {
        self.rootStore = rootStore
        self.root = rootStore.load()
    }

    /// True once `itemsDirectory()` has resolved to an iCloud-backed location.
    /// Always false under a custom root.
    var isICloudBacked: Bool { resolvedICloud }

    var capabilities: LibraryRootCapabilities { root.capabilities }

    /// Persists the new root, drops the cached directory, and bumps the
    /// generation. Returns the new generation.
    @discardableResult
    func setRoot(_ newRoot: LibraryRoot) -> Int {
        root = newRoot
        rootStore.save(newRoot)
        cachedItemsDirectory = nil
        resolvedICloud = false
        rootGeneration += 1
        return rootGeneration
    }

    /// The directory containing `<id>.json` + `<id>.<ext>` pairs.
    /// Created if needed for `.iCloud`; required to already exist for `.custom`.
    func itemsDirectory() throws -> URL {
        if let cached = cachedItemsDirectory {
            return cached
        }

        let fileManager = FileManager.default
        let resolved: URL

        switch root {
        case .custom(let url):
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                // Deliberately NOT created. See the type doc.
                throw LibraryRootError.unavailable(url)
            }
            resolved = url
            resolvedICloud = false
            cachedItemsDirectory = resolved
            return resolved

        case .iCloud:
            if let ubiquityRoot = fileManager.url(forUbiquityContainerIdentifier: Self.containerIdentifier) {
                resolved = ubiquityRoot
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent(Self.itemsFolderName, isDirectory: true)
                resolvedICloud = true
            } else {
                resolved = try Self.localFallbackDirectory()
                resolvedICloud = false
            }
        }

        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        cachedItemsDirectory = resolved

        if resolvedICloud {
            try? migrateLocalItems(into: resolved, fileManager: fileManager)
        }
        return resolved
    }

    /// The iCloud items directory if it can be resolved right now, without
    /// disturbing the active root's cache. Used to reject the app's own
    /// container as a "custom" folder.
    func iCloudItemsDirectoryIfAvailable() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.itemsFolderName, isDirectory: true)
    }

    /// `vault.json` + backup live in `Documents/` (siblings of `Items/`), so they
    /// are never enumerated as library items.
    ///
    /// Throws for a custom root: the `deletingLastPathComponent()` derivation
    /// below is a property of the iCloud layout, and under a flat custom root it
    /// would resolve to the PARENT of the user's own folder. Custom roots are
    /// unconditionally plaintext, so no caller legitimately needs this there.
    func vaultURLs() throws -> (vault: URL, backup: URL) {
        guard !root.isCustom else { throw LibraryRootError.encryptedLibrary }
        let documents = try itemsDirectory().deletingLastPathComponent()
        return (documents.appendingPathComponent("vault.json"),
                documents.appendingPathComponent("vault.backup.json"))
    }

    func metadataURL(forItemID id: Int) throws -> URL {
        try itemsDirectory().appendingPathComponent("\(id).json", isDirectory: false)
    }

    func mediaURL(forItemID id: Int, fileExtension ext: String) throws -> URL {
        try itemsDirectory().appendingPathComponent("\(id).\(ext)", isDirectory: false)
    }

    // MARK: - Local fallback

    private static func localFallbackDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(itemsFolderName, isDirectory: true)
    }

    /// Moves any items saved while iCloud was unavailable into the ubiquity
    /// container. Only ever runs for `.iCloud`.
    private func migrateLocalItems(into iCloudItems: URL, fileManager: FileManager) throws {
        let local = try Self.localFallbackDirectory()
        guard fileManager.fileExists(atPath: local.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: local,
            includingPropertiesForKeys: nil
        )
        guard !contents.isEmpty else { return }

        let coordinator = NSFileCoordinator()
        for source in contents {
            let destination = iCloudItems.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: source)
                continue
            }
            var coordinationError: NSError?
            coordinator.coordinate(
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedURL in
                try? fileManager.setUbiquitous(
                    true,
                    itemAt: source,
                    destinationURL: coordinatedURL
                )
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryContainerRootTests 2>&1 | tail -20
```

Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Run the whole suite — this file is used everywhere**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

Expected: no new failures. `LibraryTempMediaTests` may fail with `mktemp … errno 1` — that is a known environmental EPERM, not a regression; re-run that suite alone to confirm.

- [ ] **Step 6: Verify iOS still builds**

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Services/Library/LibraryContainer.swift DiffuselyTests/LibraryContainerRootTests.swift
git commit -m "feat(library): make LibraryContainer resolve an arbitrary root"
```

---

### Task 4: Discard scans that outlive their root

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift:242-320` (`reconcile`), `:798` (`rebuild`)
- Modify: `Diffusely/Services/Library/LibraryStore.swift` (`reconcileNow`, `rebuildIndex`) — the caller wiring
- Test: `DiffuselyTests/LibraryIndexGenerationTests.swift`

**Interfaces:**
- Consumes: `LibraryContainer.resolveItemsDirectory()` (Task 3) — returns `(url:generation:)` in one actor-isolated call.
- Produces: `nonisolated static func shouldApplyScan(startedAtGeneration: Int, currentGeneration: Int) -> Bool`; `reconcile` gains `startedAtGeneration: Int? = nil` and `generationProbe: @Sendable () async -> Int = { await LibraryContainer.shared.rootGeneration }`; `rebuild` gains both purely to pass them through (it delegates to `reconcile`).

**Why the caller supplies the generation.** Probing it inside `reconcile` reopens the very race the counter closes. The caller resolves the directory in one actor hop and `reconcile` would probe the generation in another; a `setRoot` landing between them pairs the OLD root's directory with the NEW root's generation, both staleness checks then agree, and the old root's scan is applied to the new root's index. `resolveItemsDirectory()` exists precisely so the pair is read atomically — so the caller reads the pair and passes both down. `startedAtGeneration: nil` means "probe now", which keeps every existing call site and test compiling unchanged.

This is the highest-value change in the feature. A scan of the old root that finishes after a switch would otherwise apply to the new root's index and prune every row it never saw — the same shape as the iCloud eviction-sweep bug class ("I didn't see the files, so they're gone"). The probe is called once before the scan and again before applying it.

The default parameter keeps every existing call site and test compiling unchanged.

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryIndexGenerationTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryIndexGenerationTests: XCTestCase {
    func testScanAppliesWhenTheGenerationIsUnchanged() {
        XCTAssertTrue(LibraryIndexService.shouldApplyScan(
            startedAtGeneration: 3, currentGeneration: 3))
    }

    func testScanIsDiscardedWhenTheRootChangedUnderIt() {
        XCTAssertFalse(LibraryIndexService.shouldApplyScan(
            startedAtGeneration: 3, currentGeneration: 4))
    }

    /// A generation can only move forward, but the predicate must not care:
    /// "different" is the whole test, so it can never be fooled into applying.
    func testAnyDifferenceDiscardsTheScan() {
        XCTAssertFalse(LibraryIndexService.shouldApplyScan(
            startedAtGeneration: 5, currentGeneration: 2))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryIndexGenerationTests 2>&1 | tail -20
```

Expected: build failure — no `shouldApplyScan`.

- [ ] **Step 3: Add the predicate**

Next to the existing `shouldReconcile` predicate in `LibraryIndexService.swift`:

```swift
    /// Pure decision extracted so it is directly unit-testable: a scan may only
    /// be applied to the index if the Library root hasn't changed since the scan
    /// started.
    ///
    /// Scans run on `scanQueue`, off the model actor, so a root switch cannot
    /// cancel one already in flight. Without this check, a scan of the OLD root
    /// finishing after the switch would be applied to the NEW root's index and
    /// prune every row it never saw — the "I didn't see the files, therefore
    /// they're gone" failure this codebase has hit before with evicted iCloud
    /// containers.
    nonisolated static func shouldApplyScan(
        startedAtGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        startedAtGeneration == currentGeneration
    }
```

- [ ] **Step 4: Thread the probe through `reconcile`**

Change the signature and add the two probe calls:

```swift
    @discardableResult
    func reconcile(
        itemsDirectory: URL,
        isPlaceholder: @escaping PlaceholderCheck = { isDatalessPlaceholder($0) },
        generationProbe: @Sendable @escaping () async -> Int = {
            await LibraryContainer.shared.rootGeneration
        }
    ) async -> ReconcileOutcome {
```

Immediately after the existing `let ctx = await LibraryVaultProvider.shared.reconcileContext()` / `shouldReconcile` guard block, capture the generation:

```swift
        let startedAtGeneration = startedAtGeneration ?? (await generationProbe())
```

Declare the parameter as `startedAtGeneration: Int? = nil` and shadow it here. A caller that resolved its directory through `resolveItemsDirectory()` passes the paired generation; a caller that did not (and every existing test) falls back to probing, which is no worse than today.

Then inside the retry loop, replace the apply block:

```swift
            if case .applied(let albumStateChanged) = applyScan(scan, ifEpochMatches: epoch) {
```

with a generation check before it:

```swift
            // The root may have been switched while this scan ran on its own
            // queue. Applying it now would write the OLD root's contents into
            // the NEW root's index and prune everything else.
            guard Self.shouldApplyScan(
                startedAtGeneration: startedAtGeneration,
                currentGeneration: await generationProbe()
            ) else {
                print("[LibraryIndex] Library root changed during the scan; discarding it")
                return .didNotScan
            }

            if case .applied(let albumStateChanged) = applyScan(scan, ifEpochMatches: epoch) {
```

- [ ] **Step 5: Wire the callers so the pair is atomic**

In `LibraryStore.reconcileNow`, replace the separate directory resolve with the paired one and pass the generation down:

```swift
            guard let resolved = try? await LibraryContainer.shared.resolveItemsDirectory() else { return }
            iCloudStatus = await LibraryContainer.shared.isICloudBacked ? .available : .unavailable
            let outcome = await indexService.reconcile(
                itemsDirectory: resolved.url,
                startedAtGeneration: resolved.generation
            )
```

Do the same in `LibraryStore.rebuildIndex`, passing `resolved.generation` to `indexService.rebuild`.

This is the whole point of the mechanism: resolving the directory and the generation in one actor-isolated call is what makes the pair trustworthy. Leaving the caller on `itemsDirectory()` alone would keep the race open no matter how careful `reconcile` is.

- [ ] **Step 6: Confirm `rebuild` inherits the check**

`rebuild(itemsDirectory:)` at `LibraryIndexService.swift:798` is a one-line delegation to `reconcile(itemsDirectory:)`, so it picks the generation check up for free — **do not** duplicate the logic there. Add the pass-through parameter only, so a caller can inject a probe:

```swift
    @discardableResult
    func rebuild(
        itemsDirectory: URL,
        startedAtGeneration: Int? = nil,
        generationProbe: @Sendable @escaping () async -> Int = {
            await LibraryContainer.shared.rootGeneration
        }
    ) async -> ReconcileOutcome {
        await reconcile(itemsDirectory: itemsDirectory,
                        startedAtGeneration: startedAtGeneration,
                        generationProbe: generationProbe)
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryIndexGenerationTests 2>&1 | tail -20
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 8: Run the index and store suites — the signature changed**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

Expected: no new failures. The default parameter means existing call sites are untouched; if anything fails to compile, it is a call site passing arguments positionally — name them rather than reordering the new parameter.

- [ ] **Step 9: Commit**

```bash
git add Diffusely/Services/Library/LibraryIndexService.swift Diffusely/Services/Library/LibraryStore.swift DiffuselyTests/LibraryIndexGenerationTests.swift
git commit -m "fix(library): discard container scans that outlive their root"
```

---

### Task 5: Gate cases and plaintext-root bootstrap in `LibraryVaultProvider`

**Files:**
- Modify: `Diffusely/Services/Library/LibraryVaultProvider.swift`
- Modify: `Diffusely/Services/Library/LibraryFileStore.swift` (stop it recreating a vanished custom root)
- Test: `DiffuselyTests/LibraryVaultProviderRootGateTests.swift`

**Interfaces:**
- Consumes: `LibraryRoot`, `LibraryContainer.root` (Tasks 1, 3).
- Produces: `LibraryGate.switchingRoot` and `LibraryGate.rootUnavailable(URL)`; `func beginRootSwitch()`, `func reportRootUnavailable(_ url: URL)`, `func endRootSwitch() async`, `func rebootstrap() async` on `LibraryVaultProvider`; `nonisolated static func computedGate(rootOverride:migrationPhase:isPlaintextRoot:vaultState:pendingPlaintextCount:) -> LibraryGate`.

Two structural points:

- The gate stays the **single** blocking mechanism. `LibraryView`, `LibraryStore.shouldAutonomousReconcile` and `SettingsView.rebuildIndexUnavailableReason` all switch on it exhaustively, and `SettingsView.swift:386` documents that as deliberate — a new case must be a compile error at every site that must handle it.
- The gate decision moves into a pure static so the new precedence is testable without the singleton. The existing `computedGate()` keeps its name and shape but delegates.

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryVaultProviderRootGateTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryVaultProviderRootGateTests: XCTestCase {
    private typealias Provider = LibraryVaultProvider

    func testSwitchingRootOutranksEverything() {
        let gate = Provider.computedGate(
            rootOverride: .switchingRoot,
            migrationPhase: .encrypting(done: 1, total: 10),
            isPlaintextRoot: false,
            vaultState: .locked,
            pendingPlaintextCount: 5
        )
        XCTAssertEqual(gate, .switchingRoot)
    }

    func testRootUnavailableOutranksEverything() {
        let url = URL(fileURLWithPath: "/Volumes/Gone/Library")
        let gate = Provider.computedGate(
            rootOverride: .rootUnavailable(url),
            migrationPhase: .encrypting(done: 1, total: 10),
            isPlaintextRoot: false,
            vaultState: .locked,
            pendingPlaintextCount: 5
        )
        XCTAssertEqual(gate, .rootUnavailable(url))
    }

    /// A custom root is unconditionally plaintext: there is no vault to consult,
    /// so it must browse immediately rather than failing closed on `nil`.
    func testPlaintextRootIsBrowsableWithNoVault() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: true,
            vaultState: nil,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .browsable)
    }

    func testUnresolvedICloudVaultStillFailsClosed() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: false,
            vaultState: nil,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .loading)
    }

    func testMigrationStillBeatsVaultState() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .encrypting(done: 2, total: 9),
            isPlaintextRoot: false,
            vaultState: .unlocked,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .migrating)
    }

    func testLockedICloudVaultStillLocks() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: false,
            vaultState: .locked,
            pendingPlaintextCount: 0
        )
        XCTAssertEqual(gate, .locked)
    }

    func testUnlockedWithPendingPlaintextIsSetupIncomplete() {
        let gate = Provider.computedGate(
            rootOverride: nil,
            migrationPhase: .idle,
            isPlaintextRoot: false,
            vaultState: .unlocked,
            pendingPlaintextCount: 3
        )
        XCTAssertEqual(gate, .setupIncomplete)
    }

    func testNeitherNewGateAllowsAnAutonomousReconcile() {
        XCTAssertFalse(LibraryStore.shouldAutonomousReconcile(givenLibraryGate: .switchingRoot))
        XCTAssertFalse(LibraryStore.shouldAutonomousReconcile(
            givenLibraryGate: .rootUnavailable(URL(fileURLWithPath: "/tmp/x"))))
    }
}
```

If `LibraryEncryptionCoordinator.Phase`'s `encrypting` case has different associated-value labels, match the existing enum — check `LibraryEncryptionCoordinator.swift` and adjust these literals rather than changing the enum.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryVaultProviderRootGateTests 2>&1 | tail -20
```

Expected: build failure — no `switchingRoot` case, no static `computedGate`.

- [ ] **Step 3: Add the two gate cases**

In `LibraryVaultProvider.LibraryGate`:

```swift
        /// A root switch is running: the old root is quiesced and the new one
        /// isn't indexed yet, so nothing may read or reconcile.
        case switchingRoot
        /// The saved custom root isn't there (unplugged volume, renamed folder),
        /// or a switch failed partway. Carries the path so the UI can name it.
        /// Deliberately blocks rather than falling back to iCloud: a reconcile
        /// against a missing root would prune the index to nothing.
        case rootUnavailable(URL)
```

- [ ] **Step 4: Add the pure gate decision and the override plumbing**

Add stored state next to `vault`:

```swift
    /// Set by `LibraryRootCoordinator` while a switch runs, or when a root is
    /// found missing. Outranks every vault consideration.
    private var rootOverride: LibraryGate?

    /// True when the active root is `.custom` — unconditionally plaintext, so
    /// there is no vault to resolve and no reason to fail closed on a nil one.
    private var isPlaintextRoot = false
```

Add the pure decision:

```swift
    /// Pure gate decision, extracted so precedence is unit-testable without the
    /// singleton. `vaultState == nil` means the vault hasn't resolved.
    nonisolated static func computedGate(
        rootOverride: LibraryGate?,
        migrationPhase: LibraryEncryptionCoordinator.Phase,
        isPlaintextRoot: Bool,
        vaultState: LibraryVault.State?,
        pendingPlaintextCount: Int
    ) -> LibraryGate {
        // A root switch, or a root that isn't there, blocks ahead of everything:
        // the vault below describes a root we may no longer be pointed at.
        if let rootOverride { return rootOverride }

        switch migrationPhase {
        case .encrypting, .decrypting:
            return .migrating
        case .idle, .failed:
            break
        }

        // A custom root is plaintext by construction — no vault, nothing to
        // fail closed about.
        if isPlaintextRoot { return .browsable }

        // Fail CLOSED, never open, when an iCloud vault hasn't resolved: a nil
        // vault must not be conflated with the real `.notConfigured` state, or a
        // reconcile could prune against the empty fallback scratch directory.
        guard let vaultState else { return .loading }

        switch vaultState {
        case .locked:
            return .locked
        case .notConfigured:
            return .browsable
        case .unlocked:
            return pendingPlaintextCount > 0 ? .setupIncomplete : .browsable
        }
    }
```

Rewrite the instance `computedGate()` to delegate. It must keep skipping the pending-plaintext scan except in the one case that needs it — that scan is blocking directory I/O:

```swift
    private func computedGate() async -> LibraryGate {
        let snapshot = await vault?.snapshot()

        // The static below is the ONLY place the gate is decided. The guard
        // here decides something narrower: whether the expensive part — a
        // blocking directory listing on `gateScanQueue` — is worth doing at
        // all. It is only ever consulted for an unlocked, configured vault
        // that nothing else is already blocking.
        let migrationBlocks: Bool
        switch migrationPhase {
        case .encrypting, .decrypting: migrationBlocks = true
        case .idle, .failed: migrationBlocks = false
        }

        var pending = 0
        if rootOverride == nil, !isPlaintextRoot, !migrationBlocks,
           snapshot?.state == .unlocked, let crypto = snapshot?.crypto {
            pending = await Self.scanPendingPlaintextCount(
                directory: resolvedDirectory(), crypto: crypto)
        }

        return Self.computedGate(
            rootOverride: rootOverride,
            migrationPhase: migrationPhase,
            isPlaintextRoot: isPlaintextRoot,
            vaultState: snapshot?.state,
            pendingPlaintextCount: pending
        )
    }
```

Note the shape: the instance method gathers inputs and delegates once. Re-implementing the precedence here as a second set of early returns would mean two decision sites that can drift, and the unit tests would only cover one of them.

- [ ] **Step 5: Skip vault bootstrap for a custom root, and support re-bootstrap**

In `resolveIfNeeded()`, inside the `Task`, branch on the root before building a vault:

```swift
            do {
                let container = LibraryContainer.shared
                let root = await container.root
                let dir = try await container.itemsDirectory()

                if root.isCustom {
                    // Custom roots are unconditionally plaintext. Build no vault
                    // at all: `vaultURLs()` throws there by design, and a nil
                    // vault already yields a passthrough file store.
                    self.finishBootstrap(vault: nil, itemsDirectory: dir, isPlaintextRoot: true)
                    return
                }

                let urls = try await container.vaultURLs()
                let vault = LibraryVault(vaultURL: urls.vault, backupURL: urls.backup,
                                          keyStore: KeychainKeyStore(), rounds: 600_000)
                self.finishBootstrap(vault: vault, itemsDirectory: dir, isPlaintextRoot: false)
            } catch let error as LibraryRootError {
                // A missing custom root is a real, reportable state — not a
                // transient hiccup to retry silently.
                if case .unavailable(let url) = error {
                    self.rootOverride = .rootUnavailable(url)
                    self.libraryGate = .rootUnavailable(url)
                }
                self.bootstrapTask = nil
            } catch {
                self.bootstrapTask = nil
            }
```

Update `finishBootstrap` and add `rebootstrap`:

```swift
    private func finishBootstrap(vault: LibraryVault?, itemsDirectory: URL, isPlaintextRoot: Bool) {
        self.vault = vault
        self.itemsDirectory = itemsDirectory
        self.isPlaintextRoot = isPlaintextRoot
    }

    /// Tears down the resolved vault and resolves again against whatever root
    /// `LibraryContainer` now holds. Used by `LibraryRootCoordinator` mid-switch.
    func rebootstrap() async {
        bootstrapTask = nil
        vault = nil
        itemsDirectory = nil
        isPlaintextRoot = false
        await resolveIfNeeded()
        await recomputeGate()
    }

    func beginRootSwitch() {
        rootOverride = .switchingRoot
        libraryGate = .switchingRoot
    }

    func reportRootUnavailable(_ url: URL) {
        rootOverride = .rootUnavailable(url)
        libraryGate = .rootUnavailable(url)
    }

    func endRootSwitch() async {
        rootOverride = nil
        await recomputeGate()
    }
```

Note `vault` becomes `LibraryVault?` at `finishBootstrap` — it already is optional on the property, so only the parameter type changes.

- [ ] **Step 6: Stop `LibraryFileStore` recreating a vanished custom root**

Task 3 guaranteed that a `.custom` root is never created — but only inside `LibraryContainer`. `LibraryFileStore` calls `createDirectory(at: itemsDirectory, withIntermediateDirectories: true)` on every write, and the container caches its resolved directory indefinitely. So a volume ejected AFTER a successful resolve leaves every caller holding a URL under a vanished mount point, and the first save recreates the folder tree there — reaching the same "empty directory that reconcile treats as authoritative" outcome one step later.

Give the store an explicit say, defaulting to today's behaviour:

```swift
    /// Whether this store may create its items directory. True for the iCloud
    /// container, which the app owns and recreates freely. FALSE for a custom
    /// root: that folder belongs to the user, and recreating it after its volume
    /// went away would manufacture an empty Library at a dead mount point —
    /// which a later reconcile would read as "every item was deleted".
    let createsContainerDirectory: Bool
```

Add it as an initializer parameter defaulting to `true`, and guard the existing `createDirectory` call on it. Then, everywhere `LibraryVaultProvider` builds a store (`fileStore()` and `reconcileContext()`), pass `createsContainerDirectory: !isPlaintextRoot` — a plaintext root is exactly a custom one.

- [ ] **Step 7: Fix the exhaustive switches the new cases break**

The compiler will point at them. Handle them minimally for now; Tasks 9 and 10 give them real UI:

- `LibraryStore.shouldAutonomousReconcile` needs no change — it is `gate == .browsable`, which already excludes both new cases. The test in Step 1 asserts that.
- `LibraryView.gatedContent` — add `case .switchingRoot, .rootUnavailable: LibraryGatePlaceholderView()` as a placeholder. Task 9 replaces it.
- `SettingsView.rebuildIndexUnavailableReason` — add `case .switchingRoot, .rootUnavailable: return nil` as a placeholder. Task 10 replaces it.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryVaultProviderRootGateTests 2>&1 | tail -20
```

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 9: Run the whole suite and the iOS build**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

- [ ] **Step 10: Commit**

```bash
git add Diffusely/Services/Library/LibraryVaultProvider.swift Diffusely/Services/Library/LibraryFileStore.swift Diffusely/Views/LibraryView.swift Diffusely/Views/SettingsView.swift DiffuselyTests/LibraryVaultProviderRootGateTests.swift
git commit -m "feat(library): gate the Library on root switching and availability"
```

---

### Task 6: Folder watcher for custom roots

**Files:**
- Create: `Diffusely/Services/Library/Root/LibraryFolderWatcher.swift`
- Test: `DiffuselyTests/LibraryFolderWatcherTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class LibraryFolderWatcher { init?(url: URL, onChange: @escaping @Sendable () -> Void); func cancel() }`. Failable: returns `nil` when the directory can't be opened.

There is no `NSMetadataQuery` for a local folder, so this supplies the same signal. It feeds the existing 750ms `ReconcileScheduler`, so bursts coalesce exactly as iCloud updates do. It fires on the app's own writes too; a redundant reconcile is idempotent and the debounce absorbs it, so that is accepted rather than filtered.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryFolderWatcherTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryFolderWatcherTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFolderWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFiresWhenAFileIsAdded() throws {
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = LibraryFolderWatcher(url: folder) { fired.fulfill() }
        XCTAssertNotNil(watcher)
        defer { watcher?.cancel() }

        try Data("{}".utf8).write(to: folder.appendingPathComponent("1.json"))
        wait(for: [fired], timeout: 5)
    }

    func testFiresWhenAFileIsRemoved() throws {
        let file = folder.appendingPathComponent("2.json")
        try Data("{}".utf8).write(to: file)

        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = LibraryFolderWatcher(url: folder) { fired.fulfill() }
        defer { watcher?.cancel() }

        try FileManager.default.removeItem(at: file)
        wait(for: [fired], timeout: 5)
    }

    func testDoesNotFireAfterCancel() throws {
        let fired = expectation(description: "watcher fired")
        fired.isInverted = true
        let watcher = LibraryFolderWatcher(url: folder) { fired.fulfill() }
        watcher?.cancel()

        try Data("{}".utf8).write(to: folder.appendingPathComponent("3.json"))
        wait(for: [fired], timeout: 2)
    }

    func testReturnsNilForAMissingFolder() {
        let missing = folder.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(LibraryFolderWatcher(url: missing) { })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryFolderWatcherTests 2>&1 | tail -20
```

Expected: build failure — `cannot find 'LibraryFolderWatcher' in scope`.

- [ ] **Step 3: Implement the watcher**

```swift
import Foundation

/// Watches a custom Library root for content changes, standing in for the
/// `NSMetadataQuery` that only exists under iCloud.
///
/// Wraps a `DispatchSource` vnode source on a file descriptor for the directory
/// itself: `.write` fires when an entry is added, removed or renamed inside it.
/// The callback is delivered on a private utility queue — never the main thread —
/// and its only consumer schedules a debounced reconcile, so the same 750ms
/// coalescing that absorbs iCloud update bursts absorbs these too.
///
/// `.delete` / `.rename` on the directory itself mean the root has gone away or
/// moved. The watcher reports that as a change like any other and cancels
/// itself; the reconcile it schedules will find the root unavailable and the
/// gate will block, which is the correct outcome — nothing here should try to
/// re-open a vanished root.
final class LibraryFolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32

    private static let queue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.folderwatcher",
        qos: .utility
    )

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: Self.queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryFolderWatcherTests 2>&1 | tail -20
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Root/LibraryFolderWatcher.swift DiffuselyTests/LibraryFolderWatcherTests.swift
git commit -m "feat(library): watch a custom Library folder for changes"
```

---

### Task 7: Capability-aware change detection and restart in `LibraryStore`

**Files:**
- Modify: `Diffusely/Services/Library/LibraryStore.swift`
- Modify: `Diffusely/Services/Library/LibraryContainer.swift` (re-validate a cached custom root)
- Test: `DiffuselyTests/LibraryContainerRootTests.swift` (extend) — the rest of the behaviour here is
  singleton- and run-loop-bound, and is covered by the ordering tests in Task 8 and the end-to-end
  verification in Task 11.

**Interfaces:**
- Consumes: `LibraryFolderWatcher` (Task 6), `LibraryContainer.capabilities` / `root` (Task 3).
- Produces: `func quiesceForRootSwitch() async` and `func restartAfterRootSwitch() async` on `LibraryStore`.

- [ ] **Step 1: Re-validate a cached custom root**

Task 3 guaranteed a custom root is never *created*, and Task 5 stopped `LibraryFileStore` recreating
one. A third hole remains: `LibraryContainer` caches its resolved directory indefinitely, so a volume
ejected AFTER a successful resolve leaves every caller holding a URL under a dead mount point. Nine
other production sites build a `LibraryFileStore` straight from that URL with the default
`createsContainerDirectory: true` — `LibraryAlbumService`, `LibraryDateBackfillService` (twice),
`SortAssistantService`, `LibraryCheckpointBackfillService`, `LibraryIndexService` among them — and any
one of their writes would recreate the tree at the dead path, manufacturing an empty Library that a
later reconcile reads as "every item was deleted".

Rather than thread the flag through all nine, close it at the source: a cached `.custom` directory is
re-checked for existence on every resolve, so a caller can never be handed a dead path in the first
place. In `itemsDirectory()`, before returning the cached value:

```swift
        if let cached = cachedItemsDirectory {
            // A custom root lives on a volume the user can eject. Re-check it
            // rather than handing back a path that no longer exists: nine other
            // call sites build a file store straight from this URL and would
            // recreate the folder tree at a dead mount point, manufacturing an
            // empty Library that reconcile then reads as "everything was
            // deleted". The iCloud container is app-owned and not ejectable, so
            // it keeps the cheap unconditional cache.
            if case .custom(let url) = root {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    cachedItemsDirectory = nil
                    throw LibraryRootError.unavailable(url)
                }
            }
            return cached
        }
```

The added cost is one `stat` per resolve under a custom root only. The spec constrains custom roots to
local volumes, so that is a local-filesystem call, not a network round trip.

Add a test to `DiffuselyTests/LibraryContainerRootTests.swift`:

```swift
    func testCachedCustomRootIsRecheckedAfterItDisappears() async throws {
        let container = makeContainer()
        let folder = tempRoot.appendingPathComponent("ejectable", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await container.setRoot(.custom(folder))
        _ = try await container.itemsDirectory()

        try FileManager.default.removeItem(at: folder)

        do {
            _ = try await container.itemsDirectory()
            XCTFail("a cached custom root must not be handed back after it disappears")
        } catch let error as LibraryRootError {
            XCTAssertEqual(error, .unavailable(folder))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "the re-check must not recreate the folder")
    }
```

- [ ] **Step 2: Replace metadata-query setup with capability-based selection**

Add a stored watcher next to `metadataQuery`:

```swift
    /// Change detection for a custom root, where there is no `NSMetadataQuery`.
    /// Exactly one of this and `metadataQuery` is ever active.
    private var folderWatcher: LibraryFolderWatcher?
```

Replace the body of `start()`'s setup branch so it picks by capability:

```swift
    func start() {
        if !didConfigureChangeDetection {
            didConfigureChangeDetection = true
            Task { await configureChangeDetection() }
        }
        guard Self.shouldStartReconcile(
            isReady: isReady,
            didReconcileSinceLaunch: didReconcileSinceLaunch
        ) else { return }
        Task {
            await reconcileNow()
            await refreshTotals()
            let isFirstReady = !isReady
            isReady = true
            // Cache enforcement belongs to the launch pass only, and only where
            // eviction means anything.
            if isFirstReady { await enforceCacheLimit() }
        }
    }
```

Rename the latch `didConfigureMetadataQuery` to `didConfigureChangeDetection`, and add:

```swift
    /// Picks the change-detection mechanism the active root supports:
    /// `NSMetadataQuery` under iCloud, a `DispatchSource` folder watcher for a
    /// custom root. Both funnel into the same debounced `reconcileScheduler`.
    private func configureChangeDetection() async {
        if await LibraryContainer.shared.capabilities.usesMetadataQuery {
            configureMetadataQuery()
            return
        }
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        folderWatcher = LibraryFolderWatcher(url: dir) { [weak self] in
            Task { @MainActor in self?.handleQueryUpdate() }
        }
    }
```

- [ ] **Step 3: Add quiesce and restart**

```swift
    /// Stops every autonomous trigger ahead of a root switch. Does NOT wait for
    /// an in-flight scan — that is what `LibraryContainer.rootGeneration` and
    /// `LibraryIndexService.shouldApplyScan` are for.
    func quiesceForRootSwitch() async {
        reconcileScheduler?.cancel()
        folderWatcher?.cancel()
        folderWatcher = nil
        if didConfigureChangeDetection {
            metadataQuery.stop()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
        didConfigureChangeDetection = false
        isReady = false
        didReconcileSinceLaunch = false
    }

    /// Re-arms everything against whatever root `LibraryContainer` now holds.
    func restartAfterRootSwitch() async {
        start()
    }
```

- [ ] **Step 4: Make the iCloud-only surfaces capability-gated**

`freeUpSpaceNow()` and `enforceCacheLimit()` both currently begin with a directory guard. Add a capability guard so neither runs where eviction is meaningless:

```swift
    func freeUpSpaceNow() async {
        guard await LibraryContainer.shared.capabilities.supportsCacheLimit else { return }
        guard (try? await LibraryContainer.shared.itemsDirectory()) != nil else { return }
        await indexService.evictAllDownloaded(store: LibraryVaultProvider.shared.fileStore())
        await refreshTotals()
    }

    func enforceCacheLimit() async {
        guard await LibraryContainer.shared.capabilities.supportsCacheLimit else { return }
        guard (try? await LibraryContainer.shared.itemsDirectory()) != nil else { return }
        await indexService.enforceCacheLimit(
            maxBytes: cacheLimitBytes,
            store: LibraryVaultProvider.shared.fileStore()
        )
        await refreshTotals()
    }
```

- [ ] **Step 5: Build and run the whole suite**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

Expected: no new failures; `BUILD SUCCEEDED` for iOS.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/LibraryStore.swift Diffusely/Services/Library/LibraryContainer.swift DiffuselyTests/LibraryContainerRootTests.swift
git commit -m "feat(library): choose change detection by root capability"
```

---

### Task 8: `LibraryRootCoordinator`

**Files:**
- Create: `Diffusely/Services/Library/Root/LibraryRootCoordinator.swift`
- Test: `DiffuselyTests/LibraryRootCoordinatorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: `@MainActor final class LibraryRootCoordinator: ObservableObject` with `struct Dependencies`, `static func live() -> LibraryRootCoordinator`, and `@discardableResult func switchTo(_ root: LibraryRoot) async -> LibraryRootError?` (`nil` = success; same `Void`-isn't-`Equatable` reason as Task 2).

Dependencies are injected closures — the codebase's existing seam style — so the ordering can be tested without touching any singleton. **Order is the contract**: quiesce and the generation bump must precede the flip, and the wipe must precede the rebuild.

A failure after the flip does **not** silently revert: a half-built index paired with a quietly-restored old root is the worst available outcome. It lands in `rootUnavailable`.

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/LibraryRootCoordinatorTests.swift`:

```swift
import XCTest
@testable import Diffusely

@MainActor
final class LibraryRootCoordinatorTests: XCTestCase {
    /// Records the sequence the coordinator drives, so ordering is asserted
    /// directly rather than inferred.
    private final class Recorder {
        var steps: [String] = []
    }

    private func makeCoordinator(
        recorder: Recorder,
        validate: @escaping (URL) -> LibraryRootError? = { _ in nil },
        rebuildFails: Bool = false
    ) -> LibraryRootCoordinator {
        let deps = LibraryRootCoordinator.Dependencies(
            validate: validate,
            beginSwitch: { recorder.steps.append("beginSwitch") },
            quiesce: { recorder.steps.append("quiesce") },
            applyRoot: { _ in recorder.steps.append("applyRoot") },
            rebootstrapVault: { recorder.steps.append("rebootstrapVault") },
            wipeIndex: { recorder.steps.append("wipeIndex") },
            rebuildIndex: {
                recorder.steps.append("rebuildIndex")
                if rebuildFails { throw LibraryRootError.unavailable(URL(fileURLWithPath: "/tmp/gone")) }
            },
            restartStore: { recorder.steps.append("restartStore") },
            endSwitch: { recorder.steps.append("endSwitch") },
            reportUnavailable: { _ in recorder.steps.append("reportUnavailable") }
        )
        return LibraryRootCoordinator(dependencies: deps)
    }

    func testHappyPathRunsEveryStepInOrder() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        XCTAssertNil(error)
        XCTAssertEqual(recorder.steps, [
            "beginSwitch", "quiesce", "applyRoot", "rebootstrapVault",
            "wipeIndex", "rebuildIndex", "restartStore", "endSwitch"
        ])
    }

    func testQuiesceHappensBeforeTheRootIsApplied() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        _ = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        let quiesce = recorder.steps.firstIndex(of: "quiesce")!
        let apply = recorder.steps.firstIndex(of: "applyRoot")!
        XCTAssertLessThan(quiesce, apply, "triggers must stop before the root moves")
    }

    func testIndexIsWipedBeforeItIsRebuilt() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        _ = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        let wipe = recorder.steps.firstIndex(of: "wipeIndex")!
        let rebuild = recorder.steps.firstIndex(of: "rebuildIndex")!
        XCTAssertLessThan(wipe, rebuild)
    }

    func testValidationFailureChangesNothing() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, validate: { _ in .encryptedLibrary })
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/sealed")))

        XCTAssertEqual(error, .encryptedLibrary)
        XCTAssertEqual(recorder.steps, [], "a rejected folder must not start a switch")
    }

    func testSwitchingToICloudSkipsValidation() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, validate: { _ in .notADirectory })
        let error = await coordinator.switchTo(.iCloud)

        XCTAssertNil(error)
        XCTAssertTrue(recorder.steps.contains("applyRoot"))
    }

    /// A failure past the flip must NOT quietly restore the old root — that
    /// pairs a half-built index with a root the user didn't choose.
    func testFailureAfterTheFlipReportsUnavailableAndDoesNotRevert() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, rebuildFails: true)
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/lib")))

        XCTAssertNotNil(error)
        XCTAssertTrue(recorder.steps.contains("reportUnavailable"))
        XCTAssertFalse(recorder.steps.contains("endSwitch"),
                       "a failed switch stays blocked rather than releasing the gate")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootCoordinatorTests 2>&1 | tail -20
```

Expected: build failure — `cannot find 'LibraryRootCoordinator' in scope`.

- [ ] **Step 3: Implement the coordinator**

```swift
import Foundation

/// Orchestrates a Library root switch, mirroring `LibraryEncryptionCoordinator`:
/// one @MainActor type owning a sequence whose ORDER is the contract.
///
/// Quiesce and the generation bump precede the flip so no trigger fires against
/// a root that is moving; the wipe precedes the rebuild so the index never mixes
/// two roots. An in-flight scan cannot be cancelled — it is neutralised instead
/// by the generation counter (`LibraryIndexService.shouldApplyScan`).
@MainActor
final class LibraryRootCoordinator: ObservableObject {
    struct Dependencies {
        var validate: (URL) -> LibraryRootError?
        var beginSwitch: () -> Void
        var quiesce: () async -> Void
        /// Persists the root, clears the cached directory and bumps the
        /// generation — `LibraryContainer.setRoot` does all three.
        var applyRoot: (LibraryRoot) async throws -> Void
        var rebootstrapVault: () async -> Void
        var wipeIndex: () async -> Void
        var rebuildIndex: () async throws -> Void
        var restartStore: () async -> Void
        var endSwitch: () -> Void
        var reportUnavailable: (URL) -> Void
    }

    @Published private(set) var isSwitching = false

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    @discardableResult
    func switchTo(_ root: LibraryRoot) async -> LibraryRootError? {
        // Validate BEFORE anything is touched: a rejected folder must leave the
        // current Library exactly as it was.
        if case .custom(let url) = root, let error = dependencies.validate(url) {
            return error
        }

        isSwitching = true
        defer { isSwitching = false }

        dependencies.beginSwitch()
        await dependencies.quiesce()

        do {
            try await dependencies.applyRoot(root)
            await dependencies.rebootstrapVault()
            await dependencies.wipeIndex()
            try await dependencies.rebuildIndex()
        } catch {
            // Past the flip. Deliberately no revert: restoring the old root now
            // would pair it with an index built (or half-built) for another one.
            // Block instead, and let the user choose Locate… or iCloud.
            let url = root.customURL ?? URL(fileURLWithPath: "/")
            dependencies.reportUnavailable(url)
            return (error as? LibraryRootError) ?? .unavailable(url)
        }

        await dependencies.restartStore()
        dependencies.endSwitch()
        return nil
    }
}
```

- [ ] **Step 4: Add the live wiring**

```swift
extension LibraryRootCoordinator {
    /// Production wiring against the real container, vault provider and store.
    static func live(store: LibraryStore) -> LibraryRootCoordinator {
        let provider = LibraryVaultProvider.shared
        let container = LibraryContainer.shared
        let rootStore = LibraryRootStore.standard

        return LibraryRootCoordinator(dependencies: Dependencies(
            validate: { url in
                // The iCloud directory is resolved on the container's actor, so
                // this synchronous seam takes the last known value; a nil simply
                // skips the "is the app's own container" check.
                rootStore.validate(url, iCloudItemsDirectory: nil)
            },
            beginSwitch: { provider.beginRootSwitch() },
            quiesce: { await store.quiesceForRootSwitch() },
            applyRoot: { root in await container.setRoot(root) },
            rebootstrapVault: { await provider.rebootstrap() },
            wipeIndex: { await store.indexService.wipe() },
            rebuildIndex: {
                let dir = try await container.itemsDirectory()
                await store.indexService.rebuild(itemsDirectory: dir)
            },
            restartStore: { await store.restartAfterRootSwitch() },
            endSwitch: { Task { await provider.endRootSwitch() } },
            reportUnavailable: { provider.reportRootUnavailable($0) }
        ))
    }
}
```

The `validate` seam passes `nil` for the iCloud directory here because it is synchronous; the picker in Task 10 resolves the real directory and validates with it before calling `switchTo`, so the container check does run on the path a user actually takes.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootCoordinatorTests 2>&1 | tail -20
```

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Library/Root/LibraryRootCoordinator.swift DiffuselyTests/LibraryRootCoordinatorTests.swift
git commit -m "feat(library): orchestrate Library root switches"
```

---

### Task 9: Gate views for switching and unavailable roots

**Files:**
- Create: `Diffusely/Utilities/LibraryRootPanel.swift`
- Create: `Diffusely/Services/Library/Root/LibraryLocationSwitcher.swift`
- Create: `Diffusely/Views/LibraryRootGateViews.swift`
- Modify: `Diffusely/Views/LibraryView.swift:188-197` (`gatedContent`)
- Test: `DiffuselyTests/LibraryRootUITextTests.swift`

**Interfaces:**
- Consumes: `LibraryGate` cases (Task 5), `LibraryRootCoordinator` (Task 8).
- Produces: `enum LibraryRootPanel { @MainActor static func chooseFolder() -> URL? }`; `enum LibraryLocationSwitcher` with `@MainActor static func chooseFolder() async -> Choice` (`enum Choice { case cancelled, rejected(String), chosen(URL) }`) and `@discardableResult @MainActor static func apply(_ root: LibraryRoot, store: LibraryStore) async -> String?`; `struct LibraryRootSwitchingView: View`; `struct LibraryRootUnavailableView: View` with `nonisolated static func message(forPath: String) -> String`.

`LibraryLocationSwitcher` exists so the two entry points into a switch — the Library tab's "Locate…" recovery here, and Settings' "Choose Folder…" in Task 10 — share one pick-validate-switch path instead of each implementing their own. Task 10 consumes it; do not duplicate its body there.

New gate views live in their own file rather than growing `LibraryView.swift`, which already carries four of them.

- [ ] **Step 1: Write the failing test**

Create `DiffuselyTests/LibraryRootUITextTests.swift`:

```swift
import XCTest
@testable import Diffusely

final class LibraryRootUITextTests: XCTestCase {
    func testUnavailableMessageNamesThePath() {
        let message = LibraryRootUnavailableView.message(forPath: "/Volumes/Media/Diffusely")
        XCTAssertTrue(message.contains("/Volumes/Media/Diffusely"),
                      "the user must be told WHICH folder is missing")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootUITextTests 2>&1 | tail -20
```

Expected: build failure — `cannot find 'LibraryRootUnavailableView' in scope`.

- [ ] **Step 3: Write the folder panel and the shared switch seam**

`Diffusely/Utilities/LibraryRootPanel.swift`:

```swift
#if os(macOS)
import AppKit

/// Folder picker for choosing where the Library lives. Sibling of
/// `LibraryExportPanel` — same unsandboxed assumption, different wording: this
/// URL is stored and reused across launches rather than used once.
enum LibraryRootPanel {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose the folder that holds your Library. An empty folder starts a new one."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
#endif
```

`Diffusely/Services/Library/Root/LibraryLocationSwitcher.swift`:

```swift
import Foundation

#if os(macOS)
/// The one path from "the user wants a different Library folder" to a completed
/// switch. Both entry points — Settings' "Choose Folder…" and the Library tab's
/// "Locate…" recovery — go through here, so validation, the iCloud-container
/// check and the coordinator wiring cannot drift between them.
///
/// Picking and applying are separate calls because Settings interposes a
/// confirmation between them; the recovery path applies straight away, since
/// the user is already looking at a broken Library and chose the folder to fix it.
enum LibraryLocationSwitcher {
    enum Choice {
        case cancelled
        /// The folder was rejected; carries the user-facing reason.
        case rejected(String)
        case chosen(URL)
    }

    @MainActor
    static func chooseFolder() async -> Choice {
        guard let url = LibraryRootPanel.chooseFolder() else { return .cancelled }
        // Resolved here rather than in the coordinator's synchronous validate
        // seam, so the "that's the app's own container" check actually runs on
        // the path a user takes.
        let iCloudItems = await LibraryContainer.shared.iCloudItemsDirectoryIfAvailable()
        if let error = LibraryRootStore.standard.validate(url, iCloudItemsDirectory: iCloudItems) {
            return .rejected(error.message)
        }
        return .chosen(url)
    }

    /// Returns a user-facing error message, or nil on success.
    @discardableResult
    @MainActor
    static func apply(_ root: LibraryRoot, store: LibraryStore) async -> String? {
        let coordinator = LibraryRootCoordinator.live(store: store)
        return (await coordinator.switchTo(root))?.message
    }
}
#endif
```

- [ ] **Step 4: Write the views**

```swift
import SwiftUI

/// Blocks the Library while a root switch runs. Inert by construction: it
/// touches neither the store nor any image request, because the old root is
/// quiesced and the new one isn't indexed yet.
struct LibraryRootSwitchingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Switching Library…")
                .font(.headline)
            Text("Rebuilding the index for the new location.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the saved custom root isn't there — an unplugged volume, a renamed
/// folder — or when a switch failed partway.
///
/// Deliberately a dead end with two explicit exits rather than a silent fallback
/// to iCloud: reconciling against a missing root would prune the index to
/// nothing, and quietly showing a different Library than the one the user chose
/// is its own kind of data loss.
struct LibraryRootUnavailableView: View {
    let path: String
    /// Both return a user-facing error message, or nil on success/cancel. The
    /// view owns the error surface because this gate is a dead end - there is
    /// no other UI on screen to report a failed recovery through.
    let onLocate: () async -> String?
    let onUseICloud: () async -> String?

    @State private var errorMessage: String?
    @State private var isWorking = false

    nonisolated static func message(forPath path: String) -> String {
        "Library not found at \(path)."
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("Library Not Found")
                .font(.headline)
            Text(Self.message(forPath: path))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("The folder may be on a disk that isn't connected. Nothing has been changed or deleted.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Locate…") { run(onLocate) }
                Button("Switch Back to iCloud") { run(onUseICloud) }
            }
            .disabled(isWorking)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ action: @escaping () async -> String?) {
        isWorking = true
        Task {
            errorMessage = await action()
            isWorking = false
        }
    }
}
```

- [ ] **Step 5: Wire the two cases into `LibraryView.gatedContent`**

Replace the placeholder added in Task 5, Step 6:

```swift
        case .switchingRoot:
            LibraryRootSwitchingView()
        case .rootUnavailable(let url):
            // Bind the store to a LOCAL before building the closures. Reading a
            // view property from inside an escaping content closure captures
            // `self`, which this codebase has hit as a hard-to-diagnose macOS
            // beachball. Capturing the value instead is the fix.
            let libraryStore = store
            LibraryRootUnavailableView(
                path: url.path,
                onLocate: {
                    #if os(macOS)
                    switch await LibraryLocationSwitcher.chooseFolder() {
                    case .cancelled: return nil
                    case .rejected(let message): return message
                    case .chosen(let folder):
                        return await LibraryLocationSwitcher.apply(.custom(folder), store: libraryStore)
                    }
                    #else
                    return nil
                    #endif
                },
                onUseICloud: {
                    #if os(macOS)
                    return await LibraryLocationSwitcher.apply(.iCloud, store: libraryStore)
                    #else
                    return nil
                    #endif
                }
            )
```

The gate enum is shared with iOS, so the switch must stay exhaustive there too - hence the `#if` inside the closures rather than around the whole case.

No new `@State` on `LibraryView`: the error surface belongs to the gate view, which owns it.

- [ ] **Step 6: Run the test and build**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootUITextTests 2>&1 | tail -20
```

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

Expected: `Executed 1 test, with 0 failures`; `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Utilities/LibraryRootPanel.swift Diffusely/Services/Library/Root/LibraryLocationSwitcher.swift Diffusely/Views/LibraryRootGateViews.swift Diffusely/Views/LibraryView.swift DiffuselyTests/LibraryRootUITextTests.swift
git commit -m "feat(library): gate views for switching and missing Library roots"
```

---

### Task 10: Settings — Library Location

**Files:**
- Create: `Diffusely/Views/LibraryLocationRow.swift`
- Modify: `Diffusely/Views/SettingsView.swift`
- Test: `DiffuselyTests/LibraryRootUITextTests.swift` (extend)

**Interfaces:**
- Consumes: `LibraryLocationSwitcher` and `LibraryRootPanel` (Task 9), plus everything above.
- Produces: `struct LibraryLocationRow: View` with `nonisolated static func displayName(for root: LibraryRoot) -> String`; `SettingsView.rebuildIndexUnavailableReason(gate:)` as a testable static.

The pick-validate-switch path already exists as `LibraryLocationSwitcher` (Task 9). Call it; do not re-implement panel handling, validation or coordinator wiring here.

- [ ] **Step 1: Write the failing tests**

Append to `DiffuselyTests/LibraryRootUITextTests.swift`:

```swift
    func testLocationDisplayNameForICloud() {
        XCTAssertEqual(LibraryLocationRow.displayName(for: .iCloud), "iCloud Drive")
    }

    func testLocationDisplayNameForCustomIsThePath() {
        let url = URL(fileURLWithPath: "/Volumes/Media/Diffusely Library")
        XCTAssertEqual(LibraryLocationRow.displayName(for: .custom(url)),
                       "/Volumes/Media/Diffusely Library")
    }

    func testRebuildReasonExplainsASwitchInProgress() {
        let reason = SettingsView.rebuildIndexUnavailableReason(gate: .switchingRoot)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("switching"))
    }

    func testRebuildReasonExplainsAMissingRoot() {
        let reason = SettingsView.rebuildIndexUnavailableReason(
            gate: .rootUnavailable(URL(fileURLWithPath: "/Volumes/Gone")))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("/Volumes/Gone"))
    }

    func testRebuildReasonIsNilWhenBrowsable() {
        XCTAssertNil(SettingsView.rebuildIndexUnavailableReason(gate: .browsable))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootUITextTests 2>&1 | tail -20
```

Expected: build failure — no `LibraryLocationRow`, no static reason function.

- [ ] **Step 3: Write the Settings row**

```swift
import SwiftUI

/// Settings row for the Library's location. macOS only: choosing an arbitrary
/// folder needs an unsandboxed `NSOpenPanel`, which iOS has no equivalent of
/// without security-scoped bookmark plumbing through every Library read/write.
struct LibraryLocationRow: View {
    @ObservedObject var libraryStore: LibraryStore
    @State private var root: LibraryRoot = LibraryRootStore.standard.load()
    @State private var errorMessage: String?
    @State private var pendingFolder: URL?

    nonisolated static func displayName(for root: LibraryRoot) -> String {
        switch root {
        case .iCloud: return "iCloud Drive"
        case .custom(let url): return url.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Library Location")
                Spacer()
                Text(Self.displayName(for: root))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Choose Folder…") { chooseFolder() }
                Button("Use iCloud") { switchTo(.iCloud) }
                    .disabled(!root.isCustom)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if root.isCustom {
                Text("This Library is stored as plain files in the folder above. In-app encryption is available only in iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .confirmationDialog(
            "Switch Library location?",
            isPresented: Binding(get: { pendingFolder != nil },
                                 set: { if !$0 { pendingFolder = nil } })
        ) {
            Button("Switch and Rebuild Index") {
                if let pendingFolder { switchTo(.custom(pendingFolder)) }
                pendingFolder = nil
            }
            Button("Cancel", role: .cancel) { pendingFolder = nil }
        } message: {
            Text("The index will be rebuilt for the new folder now. In-app encryption isn't available outside iCloud. Nothing is moved or deleted — your current Library stays where it is.")
        }
    }

    private func chooseFolder() {
        errorMessage = nil
        #if os(macOS)
        Task {
            // Pick + validate go through the shared seam (Task 9); the
            // confirmation below is what Settings adds on top of it.
            switch await LibraryLocationSwitcher.chooseFolder() {
            case .cancelled:
                break
            case .rejected(let message):
                errorMessage = message
            case .chosen(let url):
                pendingFolder = url
            }
        }
        #endif
    }

    private func switchTo(_ target: LibraryRoot) {
        errorMessage = nil
        #if os(macOS)
        Task {
            errorMessage = await LibraryLocationSwitcher.apply(target, store: libraryStore)
            // Re-read rather than assuming the target took: a failed switch
            // leaves the persisted root wherever the coordinator left it.
            root = LibraryRootStore.standard.load()
        }
        #endif
    }
}
```

- [ ] **Step 4: Wire it into `SettingsView`**

In the Personal Library `Section`, put the location row first and make the iCloud-only controls conditional. `isCustomRoot` mirrors the row's own source of truth:

```swift
    @State private var isCustomRoot = LibraryRootStore.standard.load().isCustom
```

```swift
        Section {
            #if os(macOS)
            LibraryLocationRow(libraryStore: libraryStore)
            #endif

            if !isCustomRoot {
                HStack {
                    Text("iCloud Sync")
                    // …existing iCloudStatus switch unchanged…
                }
            }

            HStack {
                Text("Downloaded on This Device")
                // …unchanged…
            }

            if !isCustomRoot {
                Picker("Keep Up To", selection: $cacheLimitGB) {
                    // …unchanged…
                }
                .onChange(of: cacheLimitGB) { _, newValue in
                    libraryStore.cacheLimitBytes = newValue * 1024 * 1024 * 1024
                }

                Button("Free Up Space Now") {
                    Task { await libraryStore.freeUpSpaceNow() }
                }
            }

            // …Rebuild Index block unchanged…
```

Disable the encryption row at a custom root, replacing the existing `#if os(iOS)` / `#else` block's macOS branch:

```swift
            #if os(iOS)
            NavigationLink {
                LibraryEncryptionSettingsView(provider: vaultProvider)
            } label: {
                libraryEncryptionRow
            }
            #else
            Button {
                showingLibraryEncryption = true
            } label: {
                libraryEncryptionRow
            }
            .buttonStyle(.plain)
            .disabled(isCustomRoot)

            if isCustomRoot {
                Text("Library Encryption is available only when your Library is in iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            #endif
```

Name the path in the reset confirmation. Replace the existing alert's message with one that says what will be emptied:

```swift
            .alert("Reset Library", isPresented: $showingResetConfirmation) {
                Button("Delete Everything", role: .destructive) {
                    Task { await libraryStore.resetLibrary() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(resetLibraryWarning)
            }
```

```swift
    /// Names the folder at a custom root: "Reset Library" empties the items
    /// directory, and there that directory is the user's own folder.
    private var resetLibraryWarning: String {
        switch LibraryRootStore.standard.load() {
        case .iCloud:
            return "This deletes every item in your Library."
        case .custom(let url):
            return "This deletes every Library file in \(url.path)."
        }
    }
```

- [ ] **Step 5: Make the rebuild reason testable and cover the new gates**

Replace the computed property with a delegating pair:

```swift
    private var rebuildIndexUnavailableReason: String? {
        let gate = vaultProvider.libraryGate
        guard !LibraryStore.shouldAutonomousReconcile(givenLibraryGate: gate) else { return nil }
        return Self.rebuildIndexUnavailableReason(gate: gate)
    }

    /// Exhaustive with no `default`, so a new `LibraryVaultProvider.LibraryGate`
    /// case is a compile error here rather than silently inheriting someone
    /// else's explanation. `nonisolated static` so it is directly testable.
    nonisolated static func rebuildIndexUnavailableReason(
        gate: LibraryVaultProvider.LibraryGate
    ) -> String? {
        switch gate {
        case .browsable:
            return nil
        case .loading:
            return "Rebuild Index is unavailable while your Library is still loading."
        case .locked:
            return "Unlock your Library to rebuild the index."
        case .migrating, .setupIncomplete:
            return "Rebuild Index is unavailable while Library Encryption is finishing setup."
        case .switchingRoot:
            return "Rebuild Index is unavailable while switching Library location."
        case .rootUnavailable(let url):
            return "Library not found at \(url.path)."
        }
    }
```

- [ ] **Step 6: Run the tests and both builds**

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests/LibraryRootUITextTests 2>&1 | tail -20
```

Expected: `Executed 6 tests, with 0 failures`.

```bash
xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DiffuselyTests 2>&1 | tail -30
```

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

- [ ] **Step 7: Commit**

```bash
git add Diffusely/Views/LibraryLocationRow.swift Diffusely/Views/SettingsView.swift DiffuselyTests/LibraryRootUITextTests.swift
git commit -m "feat(library): choose the Library location in Settings"
```

---

### Task 11: End-to-end verification on the real Mac app

**Files:** none — this is manual verification of the assembled feature.

**Do not run `Reset Library` at any point.** Do not point anything at Paul's real iCloud Library except where a step explicitly says to switch back to it.

- [ ] **Step 1: Build and launch the macOS app**

```bash
xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | tail -5
```

Launch the built app from its DerivedData products directory.

- [ ] **Step 2: Switch to an empty folder**

```bash
mkdir -p /tmp/diffusely-root-test/library-a
```

Settings → Personal Library → Library Location → **Choose Folder…** → `/tmp/diffusely-root-test/library-a` → confirm.

Expected: the Library tab shows "Switching Library…", then an empty Library. The iCloud Sync row, the cache-limit picker and Free Up Space are gone. Library Encryption is disabled with its explanation.

- [ ] **Step 3: Save an item and confirm plaintext files land in the folder**

Save any image from a feed into the Library, then:

```bash
ls -la /tmp/diffusely-root-test/library-a
```

Expected: a `<id>.json` and a `<id>.jpeg` (or `.mp4`) — readable plaintext, no opaque `.m` / `.b` / `.x` names, and no `vault.json` in the folder **or its parent**:

```bash
ls -la /tmp/diffusely-root-test/
```

- [ ] **Step 4: Confirm the folder watcher works**

With the app running and the Library tab open, copy the pair to a second id from a terminal:

```bash
cp "$(ls /tmp/diffusely-root-test/library-a/*.json | head -1)" /tmp/diffusely-root-test/library-a/99999999.json
```

If a worktree-isolated shell refuses that command substitution, list the folder and copy the sidecar by its literal name instead - the point is only that one new `<id>.json` appears.

Expected: the new item appears in the grid within a second or two without a manual Rebuild Index. (It will render as a broken/missing item since its media isn't copied — that is fine; the point is that the index noticed.)

- [ ] **Step 5: Confirm a missing root blocks instead of pruning**

Quit the app, rename the folder, relaunch:

```bash
mv /tmp/diffusely-root-test/library-a /tmp/diffusely-root-test/library-moved
```

Expected: the Library tab shows "Library Not Found" naming `/tmp/diffusely-root-test/library-a`, with **Locate…** and **Switch Back to iCloud**. Nothing is created at the old path:

```bash
ls -la /tmp/diffusely-root-test/
```

Expected: no recreated `library-a`.

- [ ] **Step 6: Recover with Locate…**

Rename it back, then use **Locate…** to pick it again.

```bash
mv /tmp/diffusely-root-test/library-moved /tmp/diffusely-root-test/library-a
```

Expected: the Library opens with the items from Step 3–4 still present.

- [ ] **Step 7: Confirm an encrypted folder is refused**

```bash
mkdir -p /tmp/diffusely-root-test/sealed && touch /tmp/diffusely-root-test/sealed/vault.json
```

Choose it. Expected: rejected inline with the "encrypted Library" message, and **no switch happens** — the Library stays on `library-a`.

- [ ] **Step 8: Switch back to iCloud and verify the real Library is intact**

Settings → **Use iCloud**.

Expected, in order: the switching view, then — because encryption is enabled on the real Library — the unlock gate. Unlock it. The index rebuilds and the item count returns to its usual ~6,500. Confirm:
- Library Encryption reports its normal enabled state, not "Off".
- The iCloud Sync row, cache-limit picker and Free Up Space are all back.
- Spot-check that images load and albums are present.

- [ ] **Step 9: Clean up**

```bash
rm -rf /tmp/diffusely-root-test
```

- [ ] **Step 10: Commit any fixes**

If the manual pass turned up defects, fix them with tests first, then commit. If it was clean, there is nothing to commit — record the result in the session ledger instead.

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| `LibraryRoot` + persistence | 1 |
| `LibraryRootStore` validation table | 2 |
| Capabilities by root | 1 (values), 7 + 10 (enforcement) |
| Flat layout; chosen folder IS the items directory | 3 |
| `vaultURLs()` fails for `.custom` | 3 |
| Custom root never created | 3 |
| Root generation counter | 3 (counter), 4 (enforcement) |
| `LibraryRootCoordinator` 7-step sequence | 8 |
| `switchingRoot` / `rootUnavailable` gates | 5 (cases), 9 (views) |
| Failed switch does not revert | 8 |
| Folder watcher → `ReconcileScheduler` | 6, 7 |
| Settings location row, disabled encryption, hidden cache controls | 10 |
| Reset confirmation names the path | 10 |
| Round-trip verification on real data | 11 |

**Placeholders:** none — every code step carries the actual code.

**Type consistency:** `LibraryRoot` / `LibraryRootCapabilities` / `LibraryRootError` (Task 1) are used unchanged in 2, 3, 5, 8, 9, 10. `setRoot` returns `Int` in Task 3 and is used for its side effects in Task 8's `applyRoot`, which is `(LibraryRoot) async throws -> Void` — the discardable result makes that legal. `shouldApplyScan(startedAtGeneration:currentGeneration:)` is named identically in Tasks 4's predicate, call sites and tests. `finishBootstrap` gains its `isPlaintextRoot` parameter in Task 5 and has no other callers.

**Known follow-ups (deliberately not in scope):** `LibraryRootCoordinator.live`'s `validate` seam passes `nil` for the iCloud directory because the closure is synchronous; the real container check runs in `LibraryLocationRow.chooseFolder` before `switchTo`. If a second caller of `switchTo` ever appears, that check needs to move into the coordinator as an async seam.
