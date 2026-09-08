import Foundation

/// Watches a custom Library root for content changes, standing in for the
/// `NSMetadataQuery` that only exists under iCloud.
///
/// Wraps a `DispatchSource` vnode source on a file descriptor for the directory
/// itself: `.write` fires when an entry is added, removed or renamed inside it.
/// The callback is delivered on a private utility queue — never the main thread —
/// and its only consumer schedules a debounced reconcile, so the same 750ms
/// coalescing that absorbs iCloud update bursts absorbs these too.
///
/// `.delete` / `.rename` on the directory itself mean the root has gone away or
/// moved. The watcher reports that as a change like any other; the reconcile
/// it schedules will find the root unavailable and the gate will block, which
/// is the correct outcome — nothing here should try to re-open a vanished root.
/// The watcher does NOT cancel itself when the directory is deleted — the owner
/// must call `cancel()` to close the descriptor. Holding it open costs nothing
/// because it is opened with `O_EVTONLY`.
final class LibraryFolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32

    private static let queue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.folderwatcher",
        qos: .utility
    )

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: Self.queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
