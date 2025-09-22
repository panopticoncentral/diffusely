import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var selectedRating: ContentRating = .g
    @State private var selectedPeriod: Timeframe = .week
    @State private var selectedSort: FeedSort = .mostReactions

    var body: some View {
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

        }
    }
}

#Preview {
    ContentView()
}
