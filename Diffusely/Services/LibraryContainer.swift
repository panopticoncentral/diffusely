import Foundation

/// Resolves the on-disk directory that backs the personal library.
///
/// Prefers the app's iCloud Drive ubiquity container (`Documents/Items`) so saved
/// media + sidecar JSON sync across devices. When iCloud is unavailable (signed out,
/// disabled) it transparently falls back to a local Application Support directory so
/// the feature still works offline; local items are migrated into the ubiquity
/// container the next time it becomes available.
///
/// `url(forUbiquityContainerIdentifier:)` performs blocking I/O and returns `nil`
/// when iCloud is off, so resolution happens exactly once on a background actor and
/// the result is cached.
actor LibraryContainer {
    static let shared = LibraryContainer()

    static let containerIdentifier = "iCloud.AchatesSoftware.Diffusely"
    private static let itemsFolderName = "Items"

    private var cachedItemsDirectory: URL?
    private var resolvedICloud = false

    init() {}

    /// True once `itemsDirectory()` has resolved to an iCloud-backed location.
    var isICloudBacked: Bool { resolvedICloud }

    /// The directory containing `<id>.json` + `<id>.<ext>` pairs. Created if needed.
    func itemsDirectory() throws -> URL {
        if let cached = cachedItemsDirectory {
            return cached
        }

        let fileManager = FileManager.default
        let resolved: URL
        if let ubiquityRoot = fileManager.url(forUbiquityContainerIdentifier: Self.containerIdentifier) {
            resolved = ubiquityRoot
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(Self.itemsFolderName, isDirectory: true)
            resolvedICloud = true
        } else {
            resolved = try Self.localFallbackDirectory()
            resolvedICloud = false
        }

        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        cachedItemsDirectory = resolved

        if resolvedICloud {
            try? migrateLocalItems(into: resolved, fileManager: fileManager)
        }
        return resolved
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

    /// Moves any items saved while iCloud was unavailable into the ubiquity container.
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
