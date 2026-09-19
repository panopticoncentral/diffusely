import SwiftUI
import SwiftData

#if os(macOS)
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case images = "Images"
    case videos = "Videos"
    case collections = "Collections"
    case following = "Following"
    case library = "Library"

    var id: Self { self }

    var icon: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .videos: "video"
        case .collections: "square.stack.3d.up"
        case .library: "externaldrive.badge.icloud"
        case .following: "person.2"
        }
    }
}

/// One selection type for every sidebar row; album names can change without
/// changing identity. Library destinations are roots, not replacement pushes.
enum SidebarDestination: Hashable {
    case section(SidebarSection)
    case allAlbums
    case unfiled
    case album(UUID)

    var isLibrary: Bool {
        switch self {
        case .section(let section): section == .library
        case .allAlbums, .unfiled, .album: true
        }
    }
}

/// Lets the ⌘1–⌘5 Go-menu commands (in `DiffuselyApp`) switch the frontmost
/// window's sidebar selection, the way Mail/Music/Finder bind number keys to
/// their top-level sections.
struct SidebarSelectionKey: FocusedValueKey {
    typealias Value = Binding<SidebarSection?>
}

extension FocusedValues {
    var sidebarSelection: Binding<SidebarSection?>? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

/// Lets the File ▸ Export Library… command reach the frontmost Library view.
/// Published only while the Library is browsable, so the menu item disables
/// itself when the vault is locked or migrating.
struct ExportLibraryKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportLibrary: (() -> Void)? {
        get { self[ExportLibraryKey.self] }
        set { self[ExportLibraryKey.self] = newValue }
    }
}
#endif

struct ContentView: View {
    @EnvironmentObject private var libraryStore: LibraryStore

    #if os(macOS)
    @State private var selectedDestination: SidebarDestination? = .section(.images)
    @StateObject private var router = NavigationRouter()
    @State private var sectionPaths: [SidebarSection: [Route]] = [:]
    @ObservedObject private var vaultProvider = LibraryVaultProvider.shared
    #else
    @State private var selectedTab = 0
    #endif

    /// One-time launch wiring, shared by both platform layouts so they can't
    /// drift. Order matters:
    /// 1. Reclaim any decrypted plaintext temp files left by a previous run
    ///    (`LibraryTempMedia.sweepAsync()`), which runs the blocking FileManager
    ///    I/O on a dedicated queue — never the main actor and never the Swift
    ///    concurrency cooperative pool (grey-spinner / cooperative-pool
    ///    discipline; `Task.detached` would have used the pool).
    /// 2. Resolve the vault singleton and settle its published state/gate
    ///    (`bootstrap()` + `refreshState()`) BEFORE the subsystem starts, so a
    ///    configured vault is known-locked and the subsequent reconcile's
    ///    locked-skip engages instead of scanning a locked/encrypted container.
    /// 3. Start the library subsystem (idempotent; LibraryView's own gated
    ///    `.task` is a no-op when this already ran).
    @MainActor
    private func startLibrarySubsystem() async {
        if NSClassFromString("XCTestCase") != nil { return }
        await LibraryTempMedia.sweepAsync()
        await LibraryVaultProvider.shared.bootstrap()
        await LibraryVaultProvider.shared.refreshState()
        libraryStore.start()
    }

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selectedDestination) {
                Section {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(SidebarDestination.section(section))
                    }
                }
                if vaultProvider.libraryGate == .browsable {
                    SidebarAlbums(selection: $selectedDestination)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            NavigationStack(path: $router.path) {
                ZStack {
                    switch selectedDestination ?? .section(.images) {
                    case .section(.images):
                        ImageFeedView(videos: false)
                    case .section(.videos):
                        ImageFeedView(videos: true)
                    case .section(.collections):
                        CollectionsView()
                    case .section(.library):
                        LibraryView()
                    case .section(.following):
                        FollowingContainerView()
                    case .allAlbums:
                        LibraryView(scopeTitle: "All Albums", showsAlbums: true)
                    case .unfiled:
                        LibraryView(filter: .notInAnyAlbum, scopeTitle: "Not in Any Album")
                    case .album(let id):
                        LibraryView(filter: .album(id), scopeTitle: "Album")
                    }
                }
                // A changed album must get fresh query, selection, and loading state.
                .id(selectedDestination)
                .routeDestinations()
            }
            .onChange(of: selectedDestination) { old, new in
                if case .section(let section) = old, section != .library {
                    sectionPaths[section] = router.path
                }
                // Library rows always open their named scope, even after drilling
                // into an album or item. Other sections retain their browsing path.
                if case .section(let section) = new, section != .library {
                    router.path = sectionPaths[section] ?? []
                } else {
                    router.popToRoot()
                }
            }
            .onChange(of: vaultProvider.libraryGate) { _, gate in
                if gate != .browsable, selectedDestination?.isLibrary == true {
                    router.popToRoot()
                    selectedDestination = .section(.library)
                }
            }
        }
        .modifier(CollectionSheetPresenter(router: router))
        .environmentObject(router)
        .focusedSceneValue(\.sidebarSelection, Binding(
            get: {
                if case .section(let section) = selectedDestination { return section }
                return selectedDestination?.isLibrary == true ? .library : nil
            },
            set: { selectedDestination = $0.map(SidebarDestination.section) }
        ))
        // Start the library subsystem at launch so its iCloud/totals state is
        // accurate no matter which section opens first (not only the Library
        // tab), after sweeping stale plaintext temp files and resolving the
        // vault. start() is idempotent, so LibraryView's own call is a no-op.
        .task { await startLibrarySubsystem() }
        .saveFeedback()
        #else
        // Every tab is a routed NavigationStack: drill-ins (user, post, tag,
        // image) push with a system back button and edge swipe-back, instead
        // of the old chained fullScreenCovers with stacked custom X buttons.
        TabView(selection: $selectedTab) {
            RoutedNavigationStack {
                ImageFeedView(videos: false)
            }
                .tabItem {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Images")
                }
                .tag(0)

            RoutedNavigationStack {
                ImageFeedView(videos: true)
            }
                .tabItem {
                    Image(systemName: "video")
                    Text("Videos")
                }
                .tag(1)

            RoutedNavigationStack {
                CollectionsView()
            }
                .tabItem {
                    Image(systemName: "square.stack.3d.up")
                    Text("Collections")
                }
                .tag(2)

            RoutedNavigationStack {
                FollowingContainerView()
            }
                .tabItem {
                    Image(systemName: "person.2")
                    Text("Following")
                }
                .tag(3)

            RoutedNavigationStack {
                LibraryView()
            }
                .tabItem {
                    Image(systemName: "externaldrive.badge.icloud")
                    Text("Library")
                }
                .tag(4)
        }
        .task { await startLibrarySubsystem() }
        .saveFeedback()
        #endif
    }
}

#Preview {
    let container = try! ModelContainer(
        for: PersistedCollection.self,
        PersistedAuthor.self,
        PersistedImage.self,
        PersistedPost.self,
        PersistedPostImage.self,
        PersistedLibraryItem.self,
        PersistedAlbum.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ContentView()
        .environmentObject(LibraryStore(modelContainer: container))
        .modelContainer(container)
}

#if os(macOS)
private struct SidebarAlbums: View {
    @Query(sort: \PersistedAlbum.name) private var albums: [PersistedAlbum]
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: SidebarDestination?

    var body: some View {
        Section("Albums") {
            Label("All Albums", systemImage: "rectangle.stack")
                .tag(SidebarDestination.allAlbums)
            Label("Not in Any Album", systemImage: "square.grid.2x2")
                .tag(SidebarDestination.unfiled)
            ForEach(albums) { album in
                Label(album.name, systemImage: "rectangle.stack").lineLimit(1)
                .tag(SidebarDestination.album(album.id))
                .dropDestination(for: LibraryItemTransfer.self) { items, _ in
                    guard !items.isEmpty else { return false }
                    let ids = items.map(\.itemID)
                    Task { await store.setAlbumMembership(itemIDs: ids, assignments: [album.id: true]) }
                    return true
                }
            }
        }
        .onChange(of: albums.map(\.id)) { _, ids in
            if case .album(let id) = selection, !ids.contains(id) {
                selection = .allAlbums
            }
        }
    }
}
#endif
