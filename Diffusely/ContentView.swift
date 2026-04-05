import SwiftUI

#if os(macOS)
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case images = "Images"
    case videos = "Videos"
    case collections = "Collections"

    var id: Self { self }

    var icon: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .videos: "video"
        case .collections: "square.stack.3d.up"
        }
    }
}
#endif

struct ContentView: View {
    @State private var selectedRating: ContentRating = .g
    @State private var selectedPeriod: Timeframe = .week
    @State private var selectedSort: FeedSort = .mostReactions

    #if os(macOS)
    @State private var selectedSection: SidebarSection? = .images
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
            switch selectedSection ?? .images {
            case .images:
                ImageFeedView(
                    selectedRating: $selectedRating,
                    selectedPeriod: $selectedPeriod,
                    selectedSort: $selectedSort,
                    videos: false
                )
            case .videos:
                ImageFeedView(
                    selectedRating: $selectedRating,
                    selectedPeriod: $selectedPeriod,
                    selectedSort: $selectedSort,
                    videos: true
                )
            case .collections:
                CollectionsView()
            }
            }
        }
        #else
        TabView(selection: $selectedTab) {
            ImageFeedView(
                selectedRating: $selectedRating,
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
                selectedRating: $selectedRating,
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
        }
        #endif
    }
}

#Preview {
    ContentView()
}
