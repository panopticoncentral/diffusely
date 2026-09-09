import SwiftUI
import SwiftData
import os

#if os(macOS)
struct FeedCommands: Commands {
    @FocusedValue(\.refreshFeed) private var refreshFeed

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Refresh") {
                refreshFeed?()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshFeed == nil)
        }
    }
}

/// Replaces the WindowGroup's default File ▸ New Window (which otherwise owns
/// ⌘N) with a File ▸ New Collection item. It's enabled only when a
/// `CollectionsView` is frontmost and publishing the `newCollection` action.
struct CollectionCommands: Commands {
    @FocusedValue(\.newCollection) private var newCollection

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Collection") {
                newCollection?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(newCollection == nil)
        }
    }
}

/// ⌘1–⌘5 to jump to each sidebar section, matching Mail/Music/Finder.
struct NavigationCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var selection

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.rawValue) {
                    selection?.wrappedValue = section
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(selection == nil)
            }
        }
    }
}

/// File ▸ Export Library… — writes a decrypted copy of the personal Library to
/// a chosen folder. Enabled only when a browsable `LibraryView` is frontmost
/// and publishing the action.
struct ExportCommands: Commands {
    @FocusedValue(\.exportLibrary) private var exportLibrary

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Library…") {
                exportLibrary?()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(exportLibrary == nil)
        }
    }
}
#endif

@main
struct DiffuselyApp: App {
    let sharedModelContainer: ModelContainer
    @StateObject private var libraryStore: LibraryStore

    @Environment(\.scenePhase) private var scenePhase
    /// When we last entered the background; nil while foregrounded. Used to
    /// decide whether an idle auto-lock is due on the next return to `.active`.
    @State private var backgroundedAt: Date?
    /// Idle timeout after which a returning app re-locks the Library vault.
    private let autoLockThreshold: TimeInterval = 300

    init() {
        AppImagePipeline.configure()
        let container = Self.makeModelContainer()
        self.sharedModelContainer = container
        _libraryStore = StateObject(wrappedValue: LibraryStore(modelContainer: container))
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            PersistedCollection.self,
            PersistedAuthor.self,
            PersistedImage.self,
            PersistedPost.self,
            PersistedPostImage.self,
            PersistedLibraryItem.self,
            PersistedAlbum.self
        ])
        // Use an explicit store URL we fully control. The local SwiftData store is
        // a disposable cache (collections re-sync from Civitai, the personal
        // library rebuilds from the iCloud container), so we deliberately use a
        // fresh path rather than migrate the legacy `default.store` from the old
        // schema - and the failure fallback can reliably wipe exactly this file.
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storeURL = appSupport.appendingPathComponent("DiffuselyStore.sqlite")
        cleanUpLegacyStore(in: appSupport)

        // CRITICAL: opt out of CloudKit. `cloudKitDatabase` defaults to
        // `.automatic`, which - because the app now ships the iCloud entitlement -
        // would make SwiftData attempt CloudKit mirroring. That fails the schema
        // (CloudKit forbids `@Attribute(.unique)`, which several models here use).
        // iCloud sync is handled by the iCloud Drive document container, not
        // SwiftData; this store is an intentionally local, disposable index.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // "Rebuild, don't migrate": wipe and recreate rather than crash.
            //
            // Say so loudly. This silently discards the whole local index — on a
            // large library that is thousands of rows and a full container
            // rescan to get them back — and it previously left no trace at all.
            // An 8,151-row index vanished during development and cost an hour to
            // investigate, because nothing recorded that the store had been
            // destroyed OR why the open failed. The most likely trigger is a
            // schema change between builds, which is exactly what this path
            // exists to absorb, so the error is the interesting part.
            recordStoreDestruction(
                "Local store could not be opened and is being DESTROYED and rebuilt. "
                + "Every index row is discarded and will be rebuilt from the container. "
                + "Underlying error: \(error)",
                beside: storeURL
            )
            destroyStore(at: storeURL)
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }

    /// Appends to `DiffuselyStore-destroyed.log`, beside the store itself.
    ///
    /// Deliberately a FILE, not `print`, stderr, or `os.Logger`. A GUI app
    /// launched from Finder has no stdout or stderr, so those vanish exactly
    /// when this matters; and `os.Logger` output on this project's machine
    /// could not be retrieved with `log show` at all, verified with a
    /// standalone probe. A file next to the store is the one destination that
    /// is guaranteed readable afterwards.
    ///
    /// This is worth recording because destroying the store silently discards
    /// the entire local index — thousands of rows on a large library, and a
    /// full container rescan to rebuild them. An 8,151-row index disappeared
    /// during development and cost an hour, because nothing recorded either
    /// that it happened or why the open failed. Appends rather than
    /// overwrites, so a repeating problem shows a history.
    ///
    /// `Logger` is also emitted, so it shows in Console.app where that works.
    private static let storeLog = Logger(subsystem: "com.achatessoftware.diffusely", category: "store")

    private static func recordStoreDestruction(_ message: String, beside storeURL: URL) {
        storeLog.fault("\(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        let logURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("DiffuselyStore-destroyed.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if fileManager.fileExists(atPath: path) {
                let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
                recordStoreDestruction(
                    "destroying \(url.lastPathComponent)\(suffix) (\(size.map(String.init) ?? "unknown") bytes)",
                    beside: url
                )
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    /// Best-effort removal of the pre-library `default.store` so it doesn't
    /// linger as dead weight after we move to the explicit store URL.
    private static func cleanUpLegacyStore(in appSupport: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = appSupport.appendingPathComponent("default.store").path + suffix
            if fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryStore)
                // Idle auto-lock: on return to the foreground past the idle
                // threshold, re-lock the Library vault so it demands an unlock
                // again. We don't lock on `.background` itself — only on the
                // next `.active` if enough time has passed (matches the plan).
                // Locking is a structural no-op when the vault isn't unlocked
                // (it just clears an already-nil DEK), and it touches ONLY the
                // Library gate — the feed tabs stay fully usable.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        backgroundedAt = Date()
                    case .active:
                        if let at = backgroundedAt,
                           Date().timeIntervalSince(at) > autoLockThreshold {
                            Task {
                                await LibraryVaultProvider.shared.vault?.lock()
                                await LibraryVaultProvider.shared.refreshState()
                            }
                        }
                        backgroundedAt = nil
                    default:
                        break
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        .commands {
            FeedCommands()
            CollectionCommands()
            NavigationCommands()
            ExportCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(libraryStore)
        }
        #endif
    }
}
