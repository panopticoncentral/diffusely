import Foundation

/// Where the personal Library lives.
///
/// `.iCloud` is the app's ubiquity container (with its Application Support
/// fallback when iCloud is off) — the only root that may be encrypted at rest.
/// `.custom` is a local folder the user chose, which IS the items directory:
/// flat `<id>.json` / `<id>.<ext>` / `album-<uuid>.json`, exactly the layout
/// `LibraryExporter` writes, so an export destination opens in place.
enum LibraryRoot: Equatable {
    case iCloud
    case custom(URL)

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var customURL: URL? {
        if case .custom(let url) = self { return url }
        return nil
    }

    var capabilities: LibraryRootCapabilities {
        switch self {
        case .iCloud:
            return LibraryRootCapabilities(
                allowsEncryption: true,
                usesMetadataQuery: true,
                supportsCacheLimit: true
            )
        case .custom:
            // Encryption is an iCloud-only concern: a folder the user chose is
            // storage they control and can encrypt themselves. The other two
            // are iCloud mechanisms with no local equivalent — and a cache
            // limit in particular would be a control that silently does nothing,
            // since `evictUbiquitousItem` is a no-op on a plain file.
            return LibraryRootCapabilities(
                allowsEncryption: false,
                usesMetadataQuery: false,
                supportsCacheLimit: false
            )
        }
    }
}

/// What the active root can do. Every field here has a real consumer — the
/// policy is encoded once, and read where it is enforced.
///
/// There is deliberately NO `supportsMaterialization` flag. Materialization is
/// decided per FILE, not per root: `LibraryFileMaterializer.isReady` reports a
/// non-ubiquitous file that exists as already local and
/// `LibraryFileMaterializer.download` refuses a non-ubiquitous target outright,
/// so a custom root's files are never downloaded and the download banner
/// (`pending > 0`) never appears there. A root-level flag would be a second,
/// weaker encoding of a rule the file-level check already enforces everywhere.
struct LibraryRootCapabilities: Equatable {
    /// Whether at-rest encryption may be offered. Read by Settings to gate the
    /// Library Encryption row (a custom root is plaintext by construction).
    let allowsEncryption: Bool
    /// `NSMetadataQuery` (iCloud) vs. a `DispatchSource` folder watcher.
    /// Read by `LibraryStore.configureChangeDetection`.
    let usesMetadataQuery: Bool
    /// Whether the cache limit / Free Up Space controls mean anything.
    /// Read by `LibraryStore.enforceCacheLimit` / `freeUpSpaceNow`.
    let supportsCacheLimit: Bool
}

enum LibraryRootError: Error, Equatable {
    case notADirectory
    case notWritable
    case encryptedLibrary
    case isICloudContainer
    case unreadable
    /// The saved custom root is not present right now (unplugged volume,
    /// renamed folder). Carries the path so the UI can name it.
    case unavailable(URL)
    /// A switch failed somewhere with no folder of its own to name — most
    /// obviously a switch back to iCloud, where there IS no user-chosen path.
    /// Exists so that case doesn't have to invent one: the old code reported
    /// `.unavailable(URL(fileURLWithPath: "/"))` and told the user their
    /// "Library [was] not found at /", a path they never chose and were then
    /// invited to Locate….
    case switchFailed
    /// A second switch arrived while one was still running. Rejected outright
    /// rather than interleaved; the current Library is untouched.
    case switchInProgress

    /// The folder this error is ABOUT, when it is about one. Lets a caller
    /// carry the real failing path forward instead of substituting a
    /// placeholder.
    var unavailableURL: URL? {
        if case .unavailable(let url) = self { return url }
        return nil
    }

    var message: String {
        switch self {
        case .notADirectory:
            return "That isn't a folder Diffusely can open."
        case .notWritable:
            return "Diffusely can't write to that folder."
        case .encryptedLibrary:
            return "That folder holds an encrypted Library. Encrypted Libraries can only be opened in iCloud."
        case .isICloudContainer:
            return "That's Diffusely's own iCloud folder — choose iCloud Drive instead."
        case .unreadable:
            return "Diffusely can't read the contents of that folder."
        case .unavailable(let url):
            return "Library not found at \(url.path)."
        case .switchFailed:
            return "Diffusely couldn't finish switching your Library location."
        case .switchInProgress:
            return "A Library location switch is already running."
        }
    }
}
