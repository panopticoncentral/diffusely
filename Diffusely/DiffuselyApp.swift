import SwiftUI
import SwiftData

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
#endif

@main
struct DiffuselyApp: App {
    let sharedModelContainer: ModelContainer
    @StateObject private var libraryStore: LibraryStore

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
            destroyStore(at: storeURL)
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }

    private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if fileManager.fileExists(atPath: path) {
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
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        .commands {
            FeedCommands()
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
