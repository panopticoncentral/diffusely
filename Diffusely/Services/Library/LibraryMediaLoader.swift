import Foundation
import AVFoundation

/// Loads a personal-library **video** for playback: transparently materializes
/// the file from iCloud (AVPlayer can't drive that itself), then hands back an
/// `AVPlayer` over the local file. The image path now goes through Nuke via
/// `LibraryImageRequest`; this loader is video-only.
///
/// When the vault is unlocked (`LibraryFileStore.isEncrypted`), the on-disk
/// media is sealed under an opaque token — AVPlayer can't play that directly,
/// so this loader decrypts it to an ephemeral plaintext temp file (via
/// `LibraryTempMedia`) and plays that instead. When the store is a passthrough
/// (not configured, or configured-but-locked), today's iCloud-materialization
/// path runs unchanged — a locked vault simply won't find `<id>.<ext>` under
/// its plaintext name, which correctly surfaces as `.failed`.
@MainActor
final class LibraryMediaLoader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double?)   // nil = indeterminate
        // `tempURL` is non-nil only for the decrypt-to-temp path (nil for the
        // plaintext/iCloud path, which plays the real container file and has
        // nothing ephemeral to clean up).
        case video(AVPlayer, tempURL: URL?)
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

    private enum DecryptError: Error { case mediaUnavailable }

    /// Dedicated queue for the blocking decrypt-to-temp work below: a
    /// coordinated `LibraryFileStore.readMedia` read (AES-GCM open) plus a
    /// synchronous Caches write. Must stay off the Swift concurrency
    /// cooperative pool for the same reason as `LibraryFileMaterializer`'s
    /// queue — see the "grey-spinner cooperative-pool-starvation" bug class.
    private static let decryptQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.videoDecrypt",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func runIO<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            decryptQueue.async { continuation.resume(returning: work()) }
        }
    }

    @Published private(set) var state: State = .idle

    private var loadTask: Task<Void, Never>?

    /// The loader is the sole owner of any decrypted plaintext temp file it
    /// writes: set only once `runEncrypted` has committed a URL to `state`,
    /// and always cleared through `cancel()`'s teardown path below (never
    /// left for the view to be the only thing that can clean it up — see
    /// `runEncrypted`'s cancellation handling for the other half of this).
    private var decryptedTempURL: URL?

    func load(itemID: Int, mediaFileName: String) {
        if case .video = state { return }       // already playing this media
        guard loadTask == nil else { return }   // a load is already in flight
        loadTask = Task { await run(itemID: itemID, mediaFileName: mediaFileName) }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        // Decrypt-to-temp path: this loader is the sole owner of the plaintext
        // temp file it wrote, so teardown always removes it here, regardless
        // of whether a view's own `onDisappear` also does so (a second
        // `LibraryTempMedia.remove` on an already-gone file is a harmless
        // no-op). Unlike the plaintext/iCloud path below, we deliberately do
        // NOT preserve `.video` state across this: the backing temp file is
        // gone, so the next `load()` must redecrypt rather than reuse a
        // player pointing at a deleted file.
        if let tempURL = decryptedTempURL {
            LibraryTempMedia.remove(tempURL)
            decryptedTempURL = nil
            state = .idle
            return
        }
        // A view that scrolls off cancels the in-flight load. Return to `.idle`
        // unless the player already loaded, so the next `onAppear` cleanly
        // restarts it.
        if case .video = state { return }
        state = .idle
    }

    private func run(itemID: Int, mediaFileName: String) async {
        let store = await LibraryVaultProvider.shared.fileStore()
        if store.isEncrypted {
            await runEncrypted(store: store, itemID: itemID, mediaFileName: mediaFileName)
            return
        }
        // Passthrough store: either encryption was never configured (today's
        // plaintext layout), or the vault is configured but locked. Both cases
        // keep today's behavior unchanged — locked-but-configured simply won't
        // find `<id>.<ext>` under its opaque encrypted name and falls through
        // to `.failed`, which is the correct "locked" outcome.
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
        state = .video(AVPlayer(url: url), tempURL: nil)
    }

    /// Decrypt-to-temp path: reads the sealed media through the vault-bound
    /// `store` (AES-GCM open) and writes the plaintext bytes to an ephemeral,
    /// Data-Protected Caches file via `LibraryTempMedia`, then plays that. The
    /// read + write both run on `decryptQueue`, off the cooperative pool,
    /// matching `LibraryFileStore`'s "never call synchronously from the
    /// cooperative pool" contract.
    private func runEncrypted(store: LibraryFileStore, itemID: Int, mediaFileName: String) async {
        // Nothing to decrypt if we're already cancelled at entry (e.g. the
        // view disappeared before this task got scheduled) — skip the
        // decrypt+write outright rather than doing pointless work we'd have
        // to immediately delete below.
        if Task.isCancelled { return }

        let ext = (mediaFileName as NSString).pathExtension
        let plaintextExt = ext.isEmpty ? "mp4" : ext

        let result: Result<URL, Error> = await Self.runIO {
            guard let data = store.readMedia(itemID: itemID, plaintextExtension: plaintextExt) else {
                return .failure(DecryptError.mediaUnavailable)
            }
            do {
                let tempURL = try LibraryTempMedia.writePlaintext(data, itemID: itemID, ext: plaintextExt)
                return .success(tempURL)
            } catch {
                return .failure(error)
            }
        }

        // `runIO`'s dispatch closure is plain (non-cooperative) work, so it
        // ran to completion regardless of cancellation — by this point,
        // on the success branch, DECRYPTED plaintext already sits on disk.
        // Cancellation can't stop that write, only prevent this file from
        // being orphaned: if the load was cancelled while the decrypt/write
        // was in flight (the ordinary case of navigating back before it
        // finishes), remove the just-written temp file immediately and
        // return without ever publishing it into `state`/`decryptedTempURL`
        // — a URL that never gets there has no other owner that would ever
        // delete it (the view's cleanup only sees URLs that reached
        // `.video`), so skipping this check would leak decrypted plaintext
        // in Caches indefinitely (Task 17's launch-time sweep is the only
        // backstop, not a guarantee for a still-running session).
        if Task.isCancelled {
            if case .success(let tempURL) = result {
                LibraryTempMedia.remove(tempURL)
            }
            return
        }

        switch result {
        case .success(let tempURL):
            decryptedTempURL = tempURL
            state = .video(AVPlayer(url: tempURL), tempURL: tempURL)
        case .failure(let error):
            logFailure(itemID: itemID, mediaFileName: mediaFileName,
                       reason: "Decrypt-to-temp failed — \((error as NSError).localizedDescription)")
            state = .failed
        }
    }

    /// Logs a local-library load failure with the same `[MediaError]` tag used by
    /// `MediaCacheService`, so the cause behind a failed video tile is visible.
    private func logFailure(itemID: Int, mediaFileName: String, reason: String) {
        print("[MediaError] Failed to load library item \(itemID) (\(mediaFileName))")
        print("[MediaError]   \(reason)")
    }
}
