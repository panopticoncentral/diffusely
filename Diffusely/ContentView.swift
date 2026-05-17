import SwiftUI

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
    case library = "Library"

    var id: Self { self }

    var icon: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .videos: "video"
        case .collections: "square.stack.3d.up"
        case .library: "externaldrive.badge.icloud"
        }
    }
}
#endif

struct ContentView: View {
    @State private var selectedPeriod: Timeframe = .week
    @State private var selectedSort: FeedSort = .mostReactions

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
                        ImageFeedView(
                            selectedPeriod: $selectedPeriod,
                            selectedSort: $selectedSort,
                            videos: false
                        )
                    case .videos:
                        ImageFeedView(
                            selectedPeriod: $selectedPeriod,
                            selectedSort: $selectedSort,
                            videos: true
                        )
                    case .collections:
                        CollectionsView()
                    case .library:
                        LibraryView()
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
            .environmentObject(feedNavigator)
            .onChange(of: selectedSection) { _, _ in
                feedNavigator.reset()
            }
        }
        #else
        TabView(selection: $selectedTab) {
            ImageFeedView(
                selectedPeriod: $selectedPeriod,
                selectedSort: $selectedSort,
                videos: false
            )
                .tabItem {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Images")
                }
                .tag(0)

            ImageFeedView(
                selectedPeriod: $selectedPeriod,
                selectedSort: $selectedSort,
                videos: true
            )
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
                LibraryView()
            }
                .tabItem {
                    Image(systemName: "externaldrive.badge.icloud")
                    Text("Library")
                }
                .tag(4)

            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(3)
        }
        #endif
    }
}

#Preview {
    ContentView()
}
