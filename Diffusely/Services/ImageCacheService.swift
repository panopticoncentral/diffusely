import SwiftUI
import Combine

@MainActor
class ImageCacheService: ObservableObject {
    static let shared = ImageCacheService()

    private var cache: [String: UIImage] = [:]
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    private var loadingStates: [String: ImageLoadingState] = [:]

    @Published private(set) var imageStates: [String: ImageLoadingState] = [:]

    enum ImageLoadingState: Equatable {
        case idle
        case loading
        case loaded(UIImage)
        case failed(Error)

        static func == (lhs: ImageLoadingState, rhs: ImageLoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading):
                return true
            case (.loaded(let img1), .loaded(let img2)):
                return img1 === img2 // Reference equality for UIImage
            case (.failed(let err1), .failed(let err2)):
                return (err1 as NSError) == (err2 as NSError)
            default:
                return false
            }
        }
    }

    private init() {}

    func getImageState(for url: String) -> ImageLoadingState {
        return imageStates[url] ?? .idle
    }

    func getImage(for url: String) -> UIImage? {
        return cache[url]
    }

    func preloadImages(urls: [String], priority: TaskPriority = .medium) {
        for url in urls {
            let currentState = imageStates[url]
            guard currentState == nil || currentState == .idle else {
                if case .failed = currentState {
                    loadImage(url: url, priority: priority)
                }
                continue
            }
            loadImage(url: url, priority: priority)
        }
    }

    func loadImage(url: String, priority: TaskPriority = .medium) {
        // Don't start new task if already loading or loaded
        let currentState = imageStates[url]
        guard currentState != .loading,
              cache[url] == nil else { return }

        // Cancel existing task if any
        loadingTasks[url]?.cancel()

        imageStates[url] = .loading

        let task = Task(priority: priority) {
            await loadImageAsync(url: url)
        }

        loadingTasks[url] = task
    }

    private func loadImageAsync(url: String) async {
        guard let imageURL = URL(string: url) else {
            await MainActor.run {
                imageStates[url] = .failed(URLError(.badURL))
                loadingTasks[url] = nil
            }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: imageURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                await MainActor.run {
                    let error = URLError(.badServerResponse)
                    imageStates[url] = .failed(error)
                    loadingTasks[url] = nil
                }
                return
            }

            guard let uiImage = UIImage(data: data) else {
                await MainActor.run {
                    let error = URLError(.cannotDecodeContentData)
                    imageStates[url] = .failed(error)
                    loadingTasks[url] = nil
                }
                return
            }

            await MainActor.run {
                cache[url] = uiImage
                imageStates[url] = .loaded(uiImage)
                loadingTasks[url] = nil
            }

        } catch {
            await MainActor.run {
                imageStates[url] = .failed(error)
                loadingTasks[url] = nil
            }
        }
    }

    func retryFailedImage(url: String) {
        let currentState = imageStates[url]
        guard case .failed = currentState else { return }
        loadImage(url: url)
    }

    func clearCache() {
        cache.removeAll()
        imageStates.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }

    func preloadAhead(currentIndex: Int, images: [CivitaiImage], lookahead: Int = 5) {
        let startIndex = max(0, currentIndex - 2) // Load a couple behind too
        let endIndex = min(images.count - 1, currentIndex + lookahead)

        let urlsToPreload = Array(images[startIndex...endIndex]).map { $0.detailURL }
        preloadImages(urls: urlsToPreload, priority: .utility)
    }
}
