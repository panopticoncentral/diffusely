import SwiftUI

struct CachedAsyncImage<Content: View, Placeholder: View, ErrorView: View>: View {
    let url: String
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    let errorView: (Error) -> ErrorView

    @StateObject private var imageCache = ImageCacheService.shared

    var body: some View {
        Group {
            switch imageCache.getImageState(for: url) {
            case .idle:
                placeholder()
                    .onAppear {
                        imageCache.loadImage(url: url)
                    }

            case .loading:
                placeholder()

            case .loaded(let uiImage):
                content(Image(uiImage: uiImage))

            case .failed(let error):
                errorView(error)
                    .onTapGesture {
                        imageCache.retryFailedImage(url: url)
                    }
            }
        }
        .onReceive(imageCache.$imageStates) { _ in
            // This ensures the view updates when image state changes
        }
    }
}

// Convenience initializers similar to AsyncImage
extension CachedAsyncImage where Content == Image, Placeholder == ProgressView<EmptyView, EmptyView>, ErrorView == Image {
    init(url: String) {
        self.url = url
        self.content = { $0 }
        self.placeholder = { ProgressView() }
        self.errorView = { _ in Image(systemName: "photo") }
    }
}

extension CachedAsyncImage where Placeholder == ProgressView<EmptyView, EmptyView>, ErrorView == Text {
    init(url: String, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.content = content
        self.placeholder = { ProgressView() }
        self.errorView = { error in Text("Failed: \(error.localizedDescription)") }
    }
}


// Simple version that matches AsyncImage API
struct CachedAsyncImageSimple: View {
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