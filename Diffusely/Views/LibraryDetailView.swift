import SwiftUI

struct LibraryDetailView: View {
    let itemID: Int

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var metadata: LibraryItemMetadata?
    @State private var loadFailed = false
    @State private var showingRemoveConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let metadata {
                    media(for: metadata)

                    VStack(alignment: .leading, spacing: 12) {
                        if let username = metadata.author.username {
                            Text(username)
                                .font(.headline)
                        }

                        if let title = metadata.sourcePostTitle, !title.isEmpty {
                            Text(title)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        if let url = URL(string: metadata.canonicalPageURL) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("Open Image on Civitai", systemImage: "safari")
                            }
                        }

                        if let postURLString = metadata.canonicalPostURL,
                           let postURL = URL(string: postURLString) {
                            Button {
                                openURL(postURL)
                            } label: {
                                Label("Open Post on Civitai", systemImage: "photo.stack")
                            }
                        }

                        Text("Saved \(metadata.savedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let genData = metadata.generationData {
                            Divider()
                            GenerationDataView(data: genData)
                        }
                    }
                    .padding()
                } else if loadFailed {
                    ContentUnavailableView("Couldn't load item", systemImage: "exclamationmark.triangle")
                        .padding(.top, 80)
                } else {
                    ProgressView().padding(.top, 80)
                }
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showingRemoveConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            "Remove from Library?",
            isPresented: $showingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.remove(itemID: itemID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your saved copy and its metadata from iCloud.")
        }
        .task { await loadMetadata() }
    }

    @ViewBuilder
    private func media(for metadata: LibraryItemMetadata) -> some View {
        let aspect = metadata.height > 0 ? CGFloat(metadata.width) / CGFloat(metadata.height) : 1
        if metadata.mediaType == .video {
            LibraryVideoPlayer(
                itemID: metadata.itemID,
                mediaFileName: metadata.mediaFileName,
                autoPlay: true,
                isMuted: false
            )
            .aspectRatio(aspect, contentMode: .fit)
        } else {
            LibraryAsyncImage(
                itemID: metadata.itemID,
                mediaFileName: metadata.mediaFileName,
                maxDimension: 2048,
                contentMode: .fit
            )
            .aspectRatio(aspect, contentMode: .fit)
        }
    }

    private func loadMetadata() async {
        guard
            let dir = try? await LibraryContainer.shared.itemsDirectory()
        else {
            loadFailed = true
            return
        }
        let jsonURL = dir.appendingPathComponent("\(itemID).json")
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: jsonURL, options: [], error: &coordError) { url in
            data = try? Data(contentsOf: url)
        }
        guard
            let data,
            let decoded = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        else {
            loadFailed = true
            return
        }
        metadata = decoded
        await store.indexService.recordAccess(itemID: itemID)
    }
}
