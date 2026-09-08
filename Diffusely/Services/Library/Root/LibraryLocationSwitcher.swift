import Foundation

#if os(macOS)
/// The one path from "the user wants a different Library folder" to a completed
/// switch. Both entry points — Settings' "Choose Folder…" and the Library tab's
/// "Locate…" recovery — go through here, so validation, the iCloud-container
/// check and the coordinator wiring cannot drift between them.
///
/// Picking and applying are separate calls because Settings interposes a
/// confirmation between them; the recovery path applies straight away, since
/// the user is already looking at a broken Library and chose the folder to fix it.
enum LibraryLocationSwitcher {
    enum Choice {
        case cancelled
        /// The folder was rejected; carries the user-facing reason.
        case rejected(String)
        case chosen(URL)
    }

    @MainActor
    static func chooseFolder() async -> Choice {
        guard let url = LibraryRootPanel.chooseFolder() else { return .cancelled }
        // Resolved here rather than in the coordinator's synchronous validate
        // seam, so the "that's the app's own container" check actually runs on
        // the path a user takes.
        let iCloudItems = await LibraryContainer.shared.iCloudItemsDirectoryIfAvailable()
        if let error = LibraryRootStore.standard.validate(url, iCloudItemsDirectory: iCloudItems) {
            return .rejected(error.message)
        }
        return .chosen(url)
    }

    /// The ONE `LibraryRootCoordinator` this process ever switches through,
    /// built on first use and reused by every later switch.
    ///
    /// This is not a caching micro-optimisation — it is what makes the
    /// coordinator's `isSwitching` re-entrancy latch real. `isSwitching` is
    /// per-instance, so while `apply` constructed a fresh coordinator per call
    /// the guard could never observe a concurrent switch and was dead in
    /// production. It is reachable: Settings' row and the Library tab's
    /// recovery gate are on screen simultaneously on macOS, and a rebuild over
    /// thousands of items is long enough for a second click. Interleaved, the
    /// first switch's `endSwitch()` would clear the `.switchingRoot` override
    /// the second one installed (the provider matches on the CASE, not on
    /// ownership), un-gating the Library and restarting the store while the
    /// second switch still had a `wipeIndex` ahead of it.
    @MainActor private static var sharedCoordinator: LibraryRootCoordinator?

    /// Returns a user-facing error message, or nil on success.
    @discardableResult
    @MainActor
    static func apply(_ root: LibraryRoot, store: LibraryStore) async -> String? {
        await apply(root, makeCoordinator: { LibraryRootCoordinator.live(store: store) })
    }

    /// The real body of `apply`, with coordinator construction as a seam.
    /// Split out so a test can drive the production entry point — shared latch
    /// included — without standing up a live `LibraryStore` and container.
    /// `makeCoordinator` runs at most once per process.
    @discardableResult
    @MainActor
    static func apply(
        _ root: LibraryRoot,
        makeCoordinator: () -> LibraryRootCoordinator
    ) async -> String? {
        let coordinator = sharedCoordinator ?? makeCoordinator()
        sharedCoordinator = coordinator
        return (await coordinator.switchTo(root))?.message
    }

    /// Drops the cached coordinator so each test starts from a clean process
    /// state. Never called in production — the instance is meant to live for
    /// the life of the app.
    @MainActor
    static func resetSharedCoordinatorForTesting() {
        sharedCoordinator = nil
    }
}
#endif
