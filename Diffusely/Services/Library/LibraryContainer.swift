import Foundation

/// Resolves the on-disk directory that backs the personal library.
///
/// The active `LibraryRoot` decides what that means:
///
/// - `.iCloud` — the app's ubiquity container (`Documents/Items`), falling back
///   to a local Application Support directory when iCloud is off, with local
///   items migrated in the next time the container becomes available. This is
///   the only root that may be encrypted at rest.
/// - `.custom` — a local folder the user chose, which IS the items directory.
///   Never created and never encrypted; if it isn't there, that's an error, not
///   something to repair (creating it would hand reconcile an empty directory
///   to treat as authoritative).
///
/// `url(forUbiquityContainerIdentifier:)` performs blocking I/O and returns
/// `nil` when iCloud is off, so resolution happens exactly once on a background
/// actor and the result is cached until the root changes.
actor LibraryContainer {
    static let shared = LibraryContainer(rootStore: .standard)

    static let containerIdentifier = "iCloud.AchatesSoftware.Diffusely"
    private static let itemsFolderName = "Items"

    private let rootStore: LibraryRootStore
    private(set) var root: LibraryRoot

    /// Monotonic counter bumped on every root change. Work started under an
    /// older generation — most importantly a container scan already running on
    /// `LibraryIndexService`'s own queue — is recognised as stale and discarded
    /// instead of being applied to the new root's index, where it would prune
    /// every row it never saw. Cancelling triggers cannot stop a scan already
    /// in flight; this can.
    private(set) var rootGeneration = 0

    private var cachedItemsDirectory: URL?
    private var resolvedICloud = false

    init(rootStore: LibraryRootStore) {
        self.rootStore = rootStore
        self.root = rootStore.load()
    }

    /// True once `itemsDirectory()` has resolved to an iCloud-backed location.
    /// Always false under a custom root.
    var isICloudBacked: Bool { resolvedICloud }

    var capabilities: LibraryRootCapabilities { root.capabilities }

    /// Persists the new root, drops the cached directory, and bumps the
    /// generation. Returns the new generation.
    @discardableResult
    func setRoot(_ newRoot: LibraryRoot) -> Int {
        root = newRoot
        rootStore.save(newRoot)
        cachedItemsDirectory = nil
        resolvedICloud = false
        rootGeneration += 1
        return rootGeneration
    }

    /// The directory containing `<id>.json` + `<id>.<ext>` pairs.
    /// Created if needed for `.iCloud`; required to already exist for `.custom`.
    func itemsDirectory() throws -> URL {
        if let cached = cachedItemsDirectory {
            // A custom root lives on a volume the user can eject. Re-check it
            // rather than handing back a path that no longer exists: nine other
            // call sites build a file store straight from this URL and would
            // recreate the folder tree at a dead mount point, manufacturing an
            // empty Library that reconcile then reads as "everything was
            // deleted". The iCloud container is app-owned and not ejectable, so
            // it keeps the cheap unconditional cache.
            if case .custom(let url) = root {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    cachedItemsDirectory = nil
                    throw LibraryRootError.unavailable(url)
                }
            }
            return cached
        }

        let fileManager = FileManager.default
        let resolved: URL

        switch root {
        case .custom(let url):
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                // Deliberately NOT created. See the type doc.
                throw LibraryRootError.unavailable(url)
            }
            resolved = url
            resolvedICloud = false
            cachedItemsDirectory = resolved
            return resolved

        case .iCloud:
            if let ubiquityRoot = fileManager.url(forUbiquityContainerIdentifier: Self.containerIdentifier) {
                resolved = ubiquityRoot
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent(Self.itemsFolderName, isDirectory: true)
                resolvedICloud = true
            } else {
                resolved = try Self.localFallbackDirectory()
                resolvedICloud = false
            }
        }

        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        cachedItemsDirectory = resolved

        if resolvedICloud {
            try? migrateLocalItems(into: resolved, fileManager: fileManager)
        }
        return resolved
    }

    /// The resolved items directory paired with the generation it belongs to,
    /// read in ONE actor-isolated call.
    ///
    /// Callers that resolve the directory and the generation separately have a
    /// race: a `setRoot` landing between those two awaits pairs the OLD root's
    /// directory with the NEW root's generation, so every later staleness check
    /// agrees and a scan of the old root is applied to the new root's index —
    /// pruning every row it never saw. This method closes that window because
    /// it suspends at no point between the two reads.
    ///
    /// Prefer this over calling `itemsDirectory()` and `rootGeneration`
    /// separately anywhere the pair is used to decide whether work is stale.
    func resolveItemsDirectory() throws -> (url: URL, generation: Int) {
        (url: try itemsDirectory(), generation: rootGeneration)
    }

    /// The iCloud items directory if it can be resolved right now, without
    /// disturbing the active root's cache. Used to reject the app's own
    /// container as a "custom" folder.
    func iCloudItemsDirectoryIfAvailable() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: Self.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.itemsFolderName, isDirectory: true)
    }

    /// `vault.json` + backup live in `Documents/` (siblings of `Items/`), so they
    /// are never enumerated as library items.
    ///
    /// Throws for a custom root: the `deletingLastPathComponent()` derivation
    /// below is a property of the iCloud layout, and under a flat custom root it
    /// would resolve to the PARENT of the user's own folder. Custom roots are
    /// unconditionally plaintext, so no caller legitimately needs this there.
    func vaultURLs() throws -> (vault: URL, backup: URL) {
        guard !root.isCustom else { throw LibraryRootError.encryptedLibrary }
        let documents = try itemsDirectory().deletingLastPathComponent()
        return (documents.appendingPathComponent("vault.json"),
                documents.appendingPathComponent("vault.backup.json"))
    }

    func metadataURL(forItemID id: Int) throws -> URL {
        try itemsDirectory().appendingPathComponent("\(id).json", isDirectory: false)
    }

    func mediaURL(forItemID id: Int, fileExtension ext: String) throws -> URL {
        try itemsDirectory().appendingPathComponent("\(id).\(ext)", isDirectory: false)
    }

    // MARK: - Local fallback

    private static func localFallbackDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(itemsFolderName, isDirectory: true)
    }

    /// Moves any items saved while iCloud was unavailable into the ubiquity
    /// container. Only ever runs for `.iCloud`.
    private func migrateLocalItems(into iCloudItems: URL, fileManager: FileManager) throws {
        let local = try Self.localFallbackDirectory()
        guard fileManager.fileExists(atPath: local.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: local,
            includingPropertiesForKeys: nil
        )
        guard !contents.isEmpty else { return }

        let coordinator = NSFileCoordinator()
        for source in contents {
            let destination = iCloudItems.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: source)
                continue
            }
            var coordinationError: NSError?
            coordinator.coordinate(
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedURL in
                try? fileManager.setUbiquitous(
                    true,
                    itemAt: source,
                    destinationURL: coordinatedURL
                )
            }
        }
    }
}
