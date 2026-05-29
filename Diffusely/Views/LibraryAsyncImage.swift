import SwiftUI

/// Renders a personal-library image from the local/iCloud container, downloading
/// it on demand if it has been evicted. Mirrors `CachedAsyncImage` but adds a
/// `.downloading` state.
struct LibraryAsyncImage: View {
    let itemID: Int
    let mediaFileName: String
    var isVideo: Bool = false
    // Default to the grid thumbnail size so the safe (cache-served) path is the
    // default — a larger default would silently route callers to the
    // full-original download path. Detail view passes an explicit larger value.
    var maxDimension: CGFloat = LibraryThumbnailStore.gridThumbnailDimension
    var contentMode: ContentMode = .fill

    @StateObject private var loader = LibraryMediaLoader()

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .downloading:
                placeholder
            case .image(let platformImage):
                Image(platformImage: platformImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .video, .failed:
                placeholder.overlay(
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundColor(.orange)
                )
            }
        }
        .onAppear {
            loader.load(itemID: itemID, mediaFileName: mediaFileName, isVideo: isVideo, maxDimension: maxDimension)
        }
        .onDisappear { loader.cancel() }
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.1))
            if case .downloading = loader.state {
                VStack(spacing: 6) {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundColor(.secondary)
                    ProgressView()
                }
            } else {
                ProgressView()
            }
        }
    }
}
