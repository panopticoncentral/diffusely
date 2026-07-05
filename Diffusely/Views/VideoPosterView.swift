import SwiftUI

/// Shows a video's still poster frame, extracted from the remote mp4 via
/// `VideoPosterProvider` (a small ranged fetch, not a full download). Renders a
/// neutral placeholder until the frame is ready. Sized by the caller so it drops
/// into a grid cell exactly like `CachedAsyncImage`.
struct VideoPosterView: View {
    let url: String
    let width: CGFloat
    let height: CGFloat

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay { ProgressView() }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: url) {
            image = await VideoPosterProvider.poster(for: url)
        }
    }
}
