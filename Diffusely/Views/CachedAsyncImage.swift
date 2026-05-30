import SwiftUI

struct CachedAsyncImage: View {
    let url: String
    var expectedAspectRatio: CGFloat?

    @State private var state: MediaLoadingState
    private let mediaCache = MediaCacheService.shared

    init(url: String, expectedAspectRatio: CGFloat? = nil) {
        self.url = url
        self.expectedAspectRatio = expectedAspectRatio
        // Seed from the in-memory cache so an already-loaded tile renders its image
        // on the first frame. Without this, a recycled LazyVGrid cell starts at
        // .idle and flashes the grey spinner placeholder for a frame before
        // onAppear swaps in the cached image — visible as jitter on fast scrolls.
        _state = State(initialValue: MediaCacheService.shared.getMediaState(for: url))
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                placeholder
                    .onAppear {
                        state = mediaCache.getMediaState(for: url)
                        mediaCache.loadMedia(url: url, isVideo: false)
                    }

            case .loading:
                placeholder

            case .loaded(let content):
                if let platformImage = content.image {
                    Image(platformImage: platformImage)
                        .resizable()
                }

            case .failed:
                placeholder
                    .overlay(
                        VStack {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.orange)
                            Text("Tap to retry")
                                .font(.caption)
                        }
                    )
                    .onTapGesture {
                        mediaCache.retryFailed(url: url, isVideo: false)
                    }
            }
        }
        // Mirror the cache entry's state. We deliberately do NOT cancel the load on
        // disappear: cancelling on SwiftUI's unreliable LazyVGrid disappear events
        // created a cancel→reload storm that saturated the CDN connection and wedged
        // requests on a permanent spinner. Instead an in-flight thumbnail load is
        // bounded by MediaCacheService's per-request timeout, runs to completion, and
        // is cached — ready instantly if the cell scrolls back into view.
        .onReceive(mediaCache.getStatePublisher(for: url)) { newState in
            state = newState
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let ratio = expectedAspectRatio {
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .aspectRatio(ratio, contentMode: .fit)
                .overlay(state.isFailed ? nil : ProgressView())
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .overlay(state.isFailed ? nil : ProgressView())
        }
    }
}
