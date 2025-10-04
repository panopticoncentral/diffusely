import SwiftUI

struct CachedAsyncImage: View {
    let url: String

    @StateObject private var mediaCache = MediaCacheService.shared

    var body: some View {
        Group {
            switch mediaCache.getMediaState(for: url) {
            case .idle:
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(ProgressView())
                    .onAppear {
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

            case .failed(_):
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
        .onReceive(mediaCache.$mediaStates) { _ in
            // Ensures view updates when media state changes
        }
    }
}
