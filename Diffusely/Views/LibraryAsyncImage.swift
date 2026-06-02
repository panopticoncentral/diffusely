import SwiftUI
import Nuke
import NukeUI

/// Renders a personal-library image from the local / iCloud container through the
/// shared Nuke pipeline. The CDN→iCloud materialization cascade lives in
/// `LibraryImageRequest`'s data closure; `LazyImage` provides bounded, prioritized
/// loading with automatic off-screen cancellation. Mirrors `CachedAsyncImage`.
struct LibraryAsyncImage: View {
    let itemID: Int
    let mediaFileName: String
    var isVideo: Bool = false
    // Default to the grid thumbnail size so the safe (disk-cached) path is the
    // default — a larger default would silently route callers to the full-original
    // download path. The detail view passes an explicit larger value.
    var maxDimension: CGFloat = LibraryImageRequest.gridDimension
    var contentMode: ContentMode = .fill

    /// Bumping this id rebuilds the LazyImage, re-issuing the request — used for
    /// tap-to-retry after a failure.
    @State private var reloadToken = 0

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else if state.error != nil {
                placeholder.overlay(
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundColor(.orange)
                )
                .contentShape(Rectangle())
                .onTapGesture { reloadToken += 1 }
            } else {
                placeholder
            }
        }
        .id(reloadToken)
    }

    private var request: ImageRequest {
        LibraryImageRequest.request(
            itemID: itemID, mediaFileName: mediaFileName,
            isVideo: isVideo, maxDimension: maxDimension)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.1))
            ProgressView()
        }
    }
}
