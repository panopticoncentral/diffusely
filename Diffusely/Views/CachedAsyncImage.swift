import SwiftUI

struct CachedAsyncImage: View {
    let url: String

    @State private var state: MediaLoadingState = .idle
    private let mediaCache = MediaCacheService.shared

    var body: some View {
        Group {
            switch state {
            case .idle:
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(ProgressView())
                    .onAppear {
                        state = mediaCache.getMediaState(for: url)
                        mediaCache.loadMedia(url: url, isVideo: false)
                    }

            case .loading:
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(ProgressView())

            case .loaded(let content):
                if let uiImage = content.image {
                    Image(uiImage: uiImage)
                        .resizable()
                }

            case .failed:
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
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
}
