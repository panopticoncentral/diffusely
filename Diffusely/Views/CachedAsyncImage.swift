import SwiftUI

struct CachedAsyncImage: View {
    let url: String

    @StateObject private var imageCache = ImageCacheService.shared

    var body: some View {
        Group {
            switch imageCache.getImageState(for: url) {
            case .idle:
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(ProgressView())
                    .onAppear {
                        imageCache.loadImage(url: url)
                    }

            case .loading:
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(ProgressView())

            case .loaded(let uiImage):
                Image(uiImage: uiImage)
                    .resizable()

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
                        imageCache.retryFailedImage(url: url)
                    }
            }
        }
        .onReceive(imageCache.$imageStates) { _ in
            // Ensures view updates when image state changes
        }
    }
}
