import SwiftUI
import SwiftData

#if os(macOS)
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case images = "Images"
    case videos = "Videos"
    case collections = "Collections"
    case users = "Users"
    case library = "Library"

    var id: Self { self }

    var icon: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .videos: "video"
        case .collections: "square.stack.3d.up"
        case .library: "externaldrive.badge.icloud"
        case .users: "person.2"
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
#endif

struct ContentView: View {
    @EnvironmentObject private var libraryStore: LibraryStore

    #if os(macOS)
    @State private var selectedSection: SidebarSection? = .images
    @StateObject private var router = NavigationRouter()
    #else
    @State private var selectedTab = 0
    #endif

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            NavigationStack(path: $router.path) {
                ZStack {
                    switch selectedSection ?? .images {
                    case .images:
                        ImageFeedView(videos: false)
                    case .videos:
                        ImageFeedView(videos: true)
                    case .collections:
                        CollectionsView()
                    case .library:
                        LibraryView()
                    case .users:
                        FollowingView()
                    }
                }
                .routeDestinations()
            }
            .onChange(of: selectedSection) { _, _ in
                router.popToRoot()
            }
        }
        .environmentObject(router)
        .focusedSceneValue(\.sidebarSelection, $selectedSection)
        // Start the library subsystem at launch so its iCloud/totals state is
        // accurate no matter which section opens first (not only the Library
        // tab). start() is idempotent, so LibraryView's own call is a no-op.
        .task { libraryStore.start() }
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
                FollowingView()
            }
                .tabItem {
                    Image(systemName: "person.2")
                    Text("Users")
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
        .task { libraryStore.start() }
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
