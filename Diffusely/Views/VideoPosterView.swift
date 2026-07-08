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
    /// Set when the poster extraction returns nil, so the view shows a retry
    /// affordance instead of an endless spinner — mirroring `CachedAsyncImage`.
    @State private var didFail = false
    /// Bumped by the retry button; part of the task id so it re-runs the fetch.
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFail {
                Button {
                    reloadToken += 1
                } label: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "play.slash")
                                    .font(.system(size: 24))
                                    .foregroundColor(.orange)
                                Text(CachedAsyncImage.retryPrompt)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Poster failed to load. \(CachedAsyncImage.retryPrompt).")
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay { ProgressView() }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: "\(url)#\(reloadToken)") {
            didFail = false
            image = nil
            if let poster = await VideoPosterProvider.poster(for: url) {
                image = poster
            } else {
                didFail = true
            }
        }
    }
}
