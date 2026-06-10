import SwiftUI

/// The "Albums" mode of the top-level Library: a grid of album cover tiles plus
/// a built-in "Not in any Album" smart tile and a "New Album" tile. Tapping an
/// album (or the smart tile) pushes a scoped `LibraryView`.
struct AlbumsBrowserView: View {
    let summaries: [LibrarySortService.AlbumSummary]
    let notInAnyAlbumCount: Int
    let onNewAlbum: () -> Void

    // Top-align cells so tiles with different caption-line counts (e.g. "New Album"
    // has no count line) keep their square covers aligned across the row.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]

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
