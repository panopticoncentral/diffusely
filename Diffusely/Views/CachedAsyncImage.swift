import SwiftUI

struct CachedAsyncImage: View {
    let url: String
    var expectedAspectRatio: CGFloat?

    @State private var state: MediaLoadingState = .idle
    private let mediaCache = MediaCacheService.shared

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
                if let uiImage = content.image {
                    Image(uiImage: uiImage)
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
