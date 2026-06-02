import Foundation
import AVFoundation

/// Loads a personal-library **video** for playback: transparently materializes
/// the file from iCloud (AVPlayer can't drive that itself), then hands back an
/// `AVPlayer` over the local file. The image path now goes through Nuke via
/// `LibraryImageRequest`; this loader is video-only.
@MainActor
final class LibraryMediaLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double?)   // nil = indeterminate
        case video(AVPlayer)
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.failed, .failed): return true
            case let (.downloading(a), .downloading(b)): return a == b
            case (.video, .video): return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private var loadTask: Task<Void, Never>?

    func load(itemID: Int, mediaFileName: String) {
        if case .video = state { return }       // already playing this media
        guard loadTask == nil else { return }   // a load is already in flight
        loadTask = Task { await run(itemID: itemID, mediaFileName: mediaFileName) }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        // A view that scrolls off cancels the in-flight load. Return to `.idle`
        // unless the player already loaded, so the next `onAppear` cleanly
        // restarts it.
        if case .video = state { return }
        state = .idle
    }

    private func run(itemID: Int, mediaFileName: String) async {
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else {
            if Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName, reason: "Library items directory unavailable")
            state = .failed
            return
        }
        let url = dir.appendingPathComponent(mediaFileName)

        do {
            if await LibraryFileMaterializer.isReady(url: url) == false {
                state = .downloading(nil)
                try await LibraryFileMaterializer.download(url: url)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            logFailure(itemID: itemID, mediaFileName: mediaFileName,
                       reason: "Download failed — \((error as NSError).localizedDescription)")
            state = .failed
            return
        }
        if Task.isCancelled { return }
        state = .video(AVPlayer(url: url))
    }

    /// Logs a local-library load failure with the same `[MediaError]` tag used by
    /// `MediaCacheService`, so the cause behind a failed video tile is visible.
    private func logFailure(itemID: Int, mediaFileName: String, reason: String) {
        print("[MediaError] Failed to load library item \(itemID) (\(mediaFileName))")
        print("[MediaError]   \(reason)")
    }
}
