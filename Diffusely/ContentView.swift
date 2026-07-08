import SwiftUI
import SwiftData

#if os(macOS)
@MainActor
final class FeedNavigator: ObservableObject {
    @Published var image: CivitaiImage?
    @Published var user: CivitaiUser?
    @Published var post: CivitaiPost?

    func push(_ image: CivitaiImage) { self.image = image }
    func push(_ user: CivitaiUser) { self.user = user }
    func push(_ post: CivitaiPost) { self.post = post }

    func reset() {
        image = nil
        user = nil
        post = nil
    }
}

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
    @StateObject private var feedNavigator = FeedNavigator()
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
            NavigationStack {
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
                .navigationDestination(item: $feedNavigator.image) { image in
                    ImageDetailView(image: image)
                }
                .navigationDestination(item: $feedNavigator.post) { post in
                    PostDetailView(post: post)
                }
                .navigationDestination(item: $feedNavigator.user) { user in
                    UserContentView(user: user)
                }
            }
            .onChange(of: selectedSection) { _, _ in
                feedNavigator.reset()
            }
        }
        .environmentObject(feedNavigator)
        .focusedSceneValue(\.sidebarSelection, $selectedSection)
        // Start the library subsystem at launch so its iCloud/totals state is
        // accurate no matter which section opens first (not only the Library
        // tab). start() is idempotent, so LibraryView's own call is a no-op.
        .task { libraryStore.start() }
        #else
        TabView(selection: $selectedTab) {
            ImageFeedView(videos: false)
                .tabItem {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Images")
                }
                .tag(0)

            ImageFeedView(videos: true)
                .tabItem {
                    Image(systemName: "video")
                    Text("Videos")
                }
                .tag(1)

            CollectionsView()
                .tabItem {
                    Image(systemName: "square.stack.3d.up")
                    Text("Collections")
                }
                .tag(2)

            NavigationStack {
                FollowingView()
            }
                .tabItem {
                    Image(systemName: "person.2")
                    Text("Users")
                }
                .tag(3)

            NavigationStack {
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
