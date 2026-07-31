import Foundation

/// Ephemeral, device-local, Data-Protected plaintext for decrypt-to-temp video
/// playback. Never synced (lives in Caches, outside the iCloud container) and
/// swept on launch + removed on player teardown.
enum LibraryTempMedia {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryPlaintext", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func writePlaintext(_ data: Data, itemID: Int, ext: String) throws -> URL {
        let url = dir.appendingPathComponent("\(itemID)-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func sweep() {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    /// Dedicated serial queue for the blocking `sweep()` above (a Caches
    /// directory listing + deletes). Kept off the Swift concurrency
    /// cooperative pool for the same reason as `decryptQueue` below — see the
    /// "grey-spinner cooperative-pool-starvation" bug class.
    private static let sweepQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.tempMediaSweep",
        qos: .utility
    )

    /// Runs the blocking `sweep()` on `sweepQueue`, suspending the caller until
    /// it finishes WITHOUT occupying a cooperative-pool thread. Launch wiring
    /// calls this instead of `Task.detached { sweep() }` (which would run the
    /// blocking I/O on the cooperative pool). Mirrors the `materialize` /
    /// `LibraryVault.runOnKDFQueue` continuation-bridge idiom.
    static func sweepAsync() async {
        await withCheckedContinuation { continuation in
            sweepQueue.async {
                sweep()
                continuation.resume()
            }
        }
    }

    // MARK: Decrypt-to-temp orchestration

    /// Dedicated queue for the blocking work inside `materialize` below (a
    /// coordinated `LibraryFileStore.readMedia` — AES-GCM open — plus a
    /// synchronous Caches write). Off the Swift concurrency cooperative pool
    /// for the same reason as `LibraryMediaLoader`'s private `decryptQueue`
    /// (the original instance of this pattern, for video playback) — see the
    /// "grey-spinner cooperative-pool-starvation" bug class.
    private static let decryptQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.tempMediaDecrypt",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Reads+decrypts `itemID`'s media through `store` and writes the
    /// plaintext to an ephemeral temp file via `writePlaintext`, entirely off
    /// the cooperative pool. Shared by every consumer that needs a real file
    /// URL for encrypted media beyond video playback (Quick Look, drag-out).
    ///
    /// Callers own the returned URL: `remove` it once you're done with it.
    /// When there's no reliable completion signal (e.g. a system-driven file
    /// copy for drag-out), it's fine to leave that to `sweep()` as the
    /// backstop instead — never leave it referenced nowhere with no cleanup
    /// path at all.
    ///
    /// Returns nil if the encrypted media can't be read (missing file,
    /// corrupt ciphertext) or the temp write fails.
    static func materialize(store: LibraryFileStore, itemID: Int, plaintextExtension ext: String) async -> URL? {
        await withCheckedContinuation { continuation in
            decryptQueue.async {
                guard let data = store.readMedia(itemID: itemID, plaintextExtension: ext) else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = try? writePlaintext(data, itemID: itemID, ext: ext)
                continuation.resume(returning: url)
            }
        }
    }
}
