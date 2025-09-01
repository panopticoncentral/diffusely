import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ImageGridView(videos: false)
                .tabItem {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Images")
                }
                .tag(0)

            ImageGridView(videos: true)
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
