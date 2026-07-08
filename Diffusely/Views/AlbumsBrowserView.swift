import SwiftUI

/// The "Albums" mode of the top-level Library: a grid of album cover tiles plus
/// a built-in "Not in any Album" smart tile and a "New Album" tile. Tapping an
/// album (or the smart tile) pushes a scoped `LibraryView`.
struct AlbumsBrowserView: View {
    let summaries: [LibrarySortService.AlbumSummary]
    let notInAnyAlbumCount: Int
    let onNewAlbum: () -> Void
    /// Album-management verbs surfaced on each tile's context menu (right-click
    /// on macOS, long-press on iOS). The parent `LibraryView` owns the rename
    /// alert / description sheet / delete confirmation these trigger, so the
    /// browser stays a dumb, testable view.
    var onRenameAlbum: (LibrarySortService.AlbumSummary) -> Void = { _ in }
    var onEditAlbumDescription: (UUID) -> Void = { _ in }
    var onDeleteAlbum: (LibrarySortService.AlbumSummary) -> Void = { _ in }
    /// Called when Library items are dropped on an album tile (macOS drag).
    var onDropItems: (_ itemIDs: [Int], _ albumID: UUID) -> Void = { _, _ in }

    // Top-align cells so tiles with different caption-line counts (e.g. "New Album"
    // has no count line) keep their square covers aligned across the row.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]

    /// The album currently under a drag (macOS), for the drop-target highlight.
    @State private var dropTargetAlbumID: UUID?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                if notInAnyAlbumCount > 0 {
                    NavigationLink {
                        LibraryView(filter: .notInAnyAlbum, scopeTitle: "Not in any Album")
                    } label: {
                        smartTile(title: "Not in any Album", count: notInAnyAlbumCount, systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.plain)
                }

                ForEach(summaries) { album in
                    NavigationLink {
                        LibraryView(filter: .album(album.id), scopeTitle: album.name)
                    } label: {
                        albumTile(album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            onRenameAlbum(album)
                        } label: { Label("Rename Album", systemImage: "pencil") }
                        Button {
                            onEditAlbumDescription(album.id)
                        } label: { Label("Edit Description", systemImage: "text.quote") }
                        Button(role: .destructive) {
                            onDeleteAlbum(album)
                        } label: { Label("Delete Album", systemImage: "trash") }
                    }
                    #if os(macOS)
                    // Accept Library items dragged onto the tile. Not reachable
                    // while Photos/Albums are exclusive modes of one window, but
                    // wired so a future album strip/sidebar gets it for free.
                    .dropDestination(for: LibraryItemTransfer.self) { transfers, _ in
                        dropTargetAlbumID = nil
                        guard !transfers.isEmpty else { return false }
                        onDropItems(transfers.map(\.itemID), album.id)
                        return true
                    } isTargeted: { targeted in
                        dropTargetAlbumID = targeted ? album.id : nil
                    }
                    .overlay {
                        if dropTargetAlbumID == album.id {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                    #endif
                }

                Button(action: onNewAlbum) {
                    smartTile(title: "New Album", count: nil, systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }

    private func albumTile(_ album: LibrarySortService.AlbumSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Drive the tile's geometry from the square background; the cover is an
            // overlay so a landscape `.fill` image can't inflate the cell and spill
            // into neighboring tiles (mirrors the main Library grid in LibraryView).
            Color(.secondarySystemBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let cover = album.coverItem {
                        LibraryAsyncImage(
                            itemID: cover.itemID, mediaFileName: cover.mediaFileName,
                            isVideo: cover.isVideo, maxDimension: LibraryImageRequest.gridDimension,
                            contentMode: .fill)
                    } else {
                        Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary).font(.title)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(album.name).font(.subheadline).lineLimit(1)
            Text("\(album.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func smartTile(title: String, count: Int?, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
                Image(systemName: systemImage).font(.title).foregroundStyle(Color.accentColor)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(title).font(.subheadline).lineLimit(1)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
