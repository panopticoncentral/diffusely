import SwiftUI
import Nuke
import NukeUI

/// Loads a remote image through the shared Nuke pipeline. `LazyImage` provides
/// bounded, prioritized loading with automatic cancellation when the cell scrolls
/// off-screen — replacing the bespoke MediaCacheService image path.
struct CachedAsyncImage: View {
    let url: String
    var expectedAspectRatio: CGFloat?

    /// Bumping this id rebuilds the LazyImage, which re-issues the request — used
    /// for tap-to-retry after a failure.
    @State private var reloadToken = 0

    init(url: String, expectedAspectRatio: CGFloat? = nil) {
        self.url = url
        self.expectedAspectRatio = expectedAspectRatio
    }

    /// Verb matches the platform's pointer idiom.
    static var retryPrompt: String {
        #if os(macOS)
        "Click to retry"
        #else
        "Tap to retry"
        #endif
    }

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image.resizable()
            } else if state.error != nil {
                Button {
                    reloadToken += 1
                } label: {
                    placeholder(showsProgress: false).overlay(
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.orange)
                            Text(Self.retryPrompt).font(.caption)
                        }
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Failed to load. \(Self.retryPrompt).")
            } else {
                placeholder()
            }
        }
        .id(reloadToken)
    }

    private var request: ImageRequest? {
        guard let u = URL(string: url) else { return nil }
        return ImageRequest(url: u, processors: [.resize(width: AppImagePipeline.maxDimension)])
    }

    @ViewBuilder
    private func placeholder(showsProgress: Bool = true) -> some View {
        if let ratio = expectedAspectRatio {
            Rectangle().fill(Color.gray.opacity(0.1))
                .aspectRatio(ratio, contentMode: .fit)
                .overlay { if showsProgress { ProgressView() } }
        } else {
            Rectangle().fill(Color.gray.opacity(0.1))
                .overlay { if showsProgress { ProgressView() } }
        }
    }
}
