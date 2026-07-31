import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct LibraryDetailView: View {
    let itemID: Int

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var metadata: LibraryItemMetadata?
    @State private var loadFailed = false
    @State private var showingRemoveConfirm = false
    @State private var embedded: EmbeddedMetadata?

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

                        if let embedded {
                            Divider()
                            EmbeddedMetadataView(metadata: embedded)
                        }
                    }
                    .padding()
                } else if loadFailed {
                    ContentUnavailableView {
                        Label("Couldn't load item", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The item couldn't be loaded from iCloud.")
                    } actions: {
                        Button("Retry") {
                            loadFailed = false
                            Task { await loadMetadata() }
                        }
                    }
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
        #if os(macOS)
        // Esc pops the pushed library item, matching the toolbar back button.
        .onExitCommand { dismiss() }
        // ⌘C copies the displayed image. Responder-chain based, so it doesn't
        // steal Copy from selected generation-metadata text.
        .onCopyCommand { imageItemProviders() }
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
        Group {
            if metadata.mediaType == .video {
                // Muted autoplay: opening a saved item shouldn't blast audio;
                // the VideoPlayer transport exposes an unmute control.
                LibraryVideoPlayer(
                    itemID: metadata.itemID,
                    mediaFileName: metadata.mediaFileName,
                    autoPlay: true,
                    isMuted: true
                )
                .aspectRatio(aspect, contentMode: .fit)
                .detailMediaFrame(maxHeight: maxHeight)
            } else {
                ZoomableView {
                    LibraryAsyncImage(
                        itemID: metadata.itemID,
                        mediaFileName: metadata.mediaFileName,
                        maxDimension: 2048,
                        contentMode: .fit
                    )
                    .aspectRatio(aspect, contentMode: .fit)
                }
                .aspectRatio(aspect, contentMode: .fit)
                .detailMediaFrame(maxHeight: maxHeight)
            }
        }
        .contextMenu {
            #if os(macOS)
            if metadata.mediaType == .image {
                Button {
                    copyCurrentImage()
                } label: { Label("Copy Image", systemImage: "doc.on.doc") }
            }
            #endif
            if let url = URL(string: metadata.canonicalPageURL) {
                Button {
                    openURL(url)
                } label: { Label("Open on Civitai", systemImage: "safari") }
                Button {
                    Clipboard.copy(metadata.canonicalPageURL)
                } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    #if os(macOS)
    /// Reads the item's original file off the main actor and writes it to the
    /// general pasteboard as an image, so ⌘C / "Copy Image" pastes it elsewhere.
    /// Images only — the file is already materialized because the detail view is
    /// displaying it. Silently no-ops if the read fails.
    private func copyCurrentImage() {
        guard let metadata, metadata.mediaType == .image else { return }
        let itemID = metadata.itemID
        let ext = (metadata.mediaFileName as NSString).pathExtension
        Task {
            let (state, fileStore) = await LibraryVaultProvider.shared.reconcileContext()
            guard state != .locked else { return }
            let nsImage = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let data = await fileStore.readMediaAsync(itemID: itemID, plaintextExtension: ext) else { return nil }
                return NSImage(data: data)
            }.value
            guard let nsImage else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }
    }

    /// Item providers backing the standard Copy command (⌘C / Edit ▸ Copy).
    /// Going through `.onCopyCommand` (rather than a view-level keyboard
    /// shortcut) keeps Copy on selected prompt text working — the command only
    /// reaches here when no text field is the first responder. The provider
    /// streams the original file bytes lazily, so no work happens unless Copy
    /// actually fires.
    private func imageItemProviders() -> [NSItemProvider] {
        guard let metadata, metadata.mediaType == .image else { return [] }
        let itemID = metadata.itemID
        let ext = (metadata.mediaFileName as NSString).pathExtension
        let typeID = UTType(filenameExtension: ext)?.identifier ?? UTType.image.identifier
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeID, visibility: .all) { completion in
            Task.detached(priority: .userInitiated) {
                let (state, fileStore) = await LibraryVaultProvider.shared.reconcileContext()
                guard state != .locked else {
                    completion(nil, CocoaError(.fileNoSuchFile)); return
                }
                let data = await fileStore.readMediaAsync(itemID: itemID, plaintextExtension: ext)
                completion(data, data == nil ? CocoaError(.fileReadCorruptFile) : nil)
            }
            return nil
        }
        return [provider]
    }
    #endif

    private func loadMetadata() async {
        let (state, fileStore) = await LibraryVaultProvider.shared.reconcileContext()
        // Defensive: T17 gates the whole Library while locked, so this
        // shouldn't normally be reached with a locked vault. If it is,
        // treat the read as unavailable rather than falling through to
        // `fileStore`'s passthrough behavior (a locked snapshot's store is
        // a plaintext passthrough by design — see `reconcileContext()` —
        // which must never be used to read legacy plaintext names over an
        // actually-encrypted container).
        guard state != .locked else {
            loadFailed = true
            return
        }
        guard
            let data = await fileStore.readMetadataAsync(itemID: itemID),
            let decoded = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
        else {
            loadFailed = true
            return
        }
        metadata = decoded
        await loadEmbeddedMetadata(for: decoded)
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

    /// Reads embedded generation metadata from the item's decrypted media bytes,
    /// off the main actor. Goes through `LibraryFileStore.readMediaAsync` (the
    /// coordinated read + AES-GCM decrypt run on its dedicated queue, never the
    /// cooperative pool) + the `Data`-based `EmbeddedMetadataReader.read(data:)`
    /// — no temp file, since ImageIO can read metadata straight out of `Data` —
    /// so this works whether or not the Library is encrypted. Silently does
    /// nothing for videos, a locked vault, or when the media can't be read.
    private func loadEmbeddedMetadata(for metadata: LibraryItemMetadata) async {
        guard metadata.mediaType == .image else { return }
        let (state, fileStore) = await LibraryVaultProvider.shared.reconcileContext()
        guard state != .locked else { return }
        let itemID = metadata.itemID
        let ext = (metadata.mediaFileName as NSString).pathExtension
        let result = await Task.detached(priority: .utility) { () -> EmbeddedMetadata? in
            guard let data = await fileStore.readMediaAsync(itemID: itemID, plaintextExtension: ext) else { return nil }
            return EmbeddedMetadataReader.read(data: data)
        }.value
        embedded = result
    }
}
