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
        GeometryReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let metadata {
                    media(for: metadata, maxHeight: proxy.size.height)

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
                            HStack(spacing: 12) {
                                Button {
                                    openURL(url)
                                } label: {
                                    Label("Open Image on Civitai", systemImage: "safari")
                                }
                                Button {
                                    Clipboard.copy(metadata.canonicalPageURL)
                                } label: {
                                    Label("Copy Link", systemImage: "doc.on.doc")
                                }
                            }
                        }

                        if let postURLString = metadata.canonicalPostURL,
                           let postURL = URL(string: postURLString) {
                            HStack(spacing: 12) {
                                Button {
                                    openURL(postURL)
                                } label: {
                                    Label("Open Post on Civitai", systemImage: "photo.stack")
                                }
                                Button {
                                    Clipboard.copy(postURLString)
                                } label: {
                                    Label("Copy Link", systemImage: "doc.on.doc")
                                }
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
                .accessibilityLabel("Remove from Library")
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
    }

    @ViewBuilder
    private func media(for metadata: LibraryItemMetadata, maxHeight: CGFloat) -> some View {
        let aspect = metadata.height > 0 ? CGFloat(metadata.width) / CGFloat(metadata.height) : 1
        if metadata.mediaType == .video {
            LibraryVideoPlayer(
                itemID: metadata.itemID,
                mediaFileName: metadata.mediaFileName,
                autoPlay: true,
                isMuted: false
            )
            .aspectRatio(aspect, contentMode: .fit)
            .detailMediaFrame(maxHeight: maxHeight)
        } else {
            LibraryAsyncImage(
                itemID: metadata.itemID,
                mediaFileName: metadata.mediaFileName,
                maxDimension: 2048,
                contentMode: .fit
            )
            .aspectRatio(aspect, contentMode: .fit)
            .detailMediaFrame(maxHeight: maxHeight)
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

        // Opportunistic publish-date catchup: if this item's date is still
        // nil (e.g. it was a draft when saved and the background scan gave
        // up), try one fresh fetch now. The user is explicitly looking at
        // this item so the API cost is justified. Updates the displayed
        // metadata if the fetch succeeded.
        if decoded.publishedAt == nil,
           let updated = await store.attemptPublishDateCatchup(for: decoded) {
            metadata = updated
        }
    }
}
