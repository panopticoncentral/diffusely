#if DEBUG
import SwiftUI

/// Deterministic UI-test surface: no network loads, library scans, or file writes.
struct UIReviewHarness: View {
    @State private var newAlbum = false
    @State private var showTags = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        SettingsAccessButton()
                        Button("New Album") { newAlbum = true }
                    }
                    CopyablePromptView(label: "Prompt", text: "First line\nSecond line\nThird line\nFourth line\nFifth line\nSixth line\nSeventh line\nEighth line")
                    Divider()
                    FeedItemStats(likeCount: 1250, heartCount: 230, laughCount: 12,
                                  cryCount: 2, commentCount: 48, dislikeCount: 3)
                    ModeControl(title: "Section", selection: $showTags) {
                        Text("Creators").tag(false)
                        Text("Tags").tag(true)
                    }
                    Text("These controls use the same components as the app's browsing and detail screens.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: AppUI.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("UI Review")
            .sheet(isPresented: $newAlbum) { CreateAlbumSheet() }
        }
    }
}
#endif
