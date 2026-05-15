import Foundation
import AVFoundation

/// Loads a personal-library media file from the iCloud container, transparently
/// triggering an on-demand download when the file has been evicted, and produces
/// either a downsampled image or an AVPlayer over the local file. Parallel to
/// `MediaCacheService` (which is remote-URL only) - shares only the ImageIO
/// downsampling helper.
@MainActor
final class LibraryMediaLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double?)   // nil = indeterminate
        case image(PlatformImage)
        case video(AVPlayer)
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.failed, .failed): return true
            case let (.downloading(a), .downloading(b)): return a == b
            case (.image, .image), (.video, .video): return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private var loadTask: Task<Void, Never>?

    func load(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) {
        guard case .idle = state else { return }
        loadTask = Task { await run(itemID: itemID, mediaFileName: mediaFileName, isVideo: isVideo, maxDimension: maxDimension) }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func run(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) async {
        guard
            let dir = try? await LibraryContainer.shared.itemsDirectory()
        else {
            state = .failed
            return
        }
        let url = dir.appendingPathComponent(mediaFileName)

        do {
            try await ensureDownloaded(url: url)
        } catch {
            state = .failed
            return
        }

        if Task.isCancelled { return }

        if isVideo {
            state = .video(AVPlayer(url: url))
            return
        }

        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        guard
            let data,
            let image = ImageDownsampler.downsample(data: data, maxDimension: maxDimension)
        else {
            state = .failed
            return
        }
        state = .image(image)
    }

    private func ensureDownloaded(url: URL) async throws {
        let fileManager = FileManager.default
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])

        // Non-ubiquitous local file that exists: ready immediately.
        if values?.isUbiquitousItem != true, fileManager.fileExists(atPath: url.path) {
            return
        }

        if values?.ubiquitousItemDownloadingStatus == .current
            || values?.ubiquitousItemDownloadingStatus == .downloaded {
            return
        }

        state = .downloading(nil)
        try fileManager.startDownloadingUbiquitousItem(at: url)

        // Poll until the file is current/downloaded (~2 min ceiling).
        for _ in 0..<240 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 500_000_000)
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current
                || v?.ubiquitousItemDownloadingStatus == .downloaded {
                return
            }
        }
        throw URLError(.timedOut)
    }
}
