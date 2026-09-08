import Foundation

/// Persists which `LibraryRoot` the app is using, and validates candidate
/// folders before a switch.
///
/// The stored form is a plain path, not a security-scoped bookmark: the Mac app
/// is unsandboxed (`Diffusely.entitlements` carries only iCloud keys — see
/// `LibraryExportPanel`), so a path is sufficient, and it is also what the
/// "Library not found" UI needs to show.
final class LibraryRootStore {
    static let defaultsKey = "library_root_path"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let standard = LibraryRootStore()

    /// Never validates: a root whose folder has vanished must still load so the
    /// blocked state can name the path instead of silently reverting to iCloud.
    func load() -> LibraryRoot {
        guard let path = defaults.string(forKey: Self.defaultsKey), !path.isEmpty else {
            return .iCloud
        }
        return .custom(URL(fileURLWithPath: path, isDirectory: true))
    }

    func save(_ root: LibraryRoot) {
        switch root {
        case .iCloud:
            defaults.removeObject(forKey: Self.defaultsKey)
        case .custom(let url):
            defaults.set(url.path, forKey: Self.defaultsKey)
        }
    }

    /// Encrypted-container markers. `vault.json` is the vault file itself;
    /// `.m` / `.b` / `.x` are `LibraryFileCrypto`'s opaque sealed-file roles
    /// (meta / media / aux). Any of them means this folder is an encrypted
    /// Library, which only iCloud may hold — and refusing it here is what stops
    /// such a folder opening as a mysteriously empty Library.
    private static let vaultFileName = "vault.json"
    private static let sealedExtensions: Set<String> = ["m", "b", "x"]

    /// `iCloudItemsDirectory` is injected rather than resolved here: resolving
    /// it is blocking, actor-isolated I/O, and the test suite must never touch
    /// the real container. Pass `nil` when it is unknown or unavailable — the
    /// container check is simply skipped.
    func validate(_ url: URL, iCloudItemsDirectory: URL?) -> LibraryRootError? {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .notADirectory
        }

        if let iCloudItemsDirectory,
           url.standardizedFileURL == iCloudItemsDirectory.standardizedFileURL {
            return .isICloudContainer
        }

        guard fileManager.isWritableFile(atPath: url.path) else {
            return .notWritable
        }

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: url.path)
        } catch {
            // A directory that exists and is writable but cannot be listed must NOT
            // be reported as valid: the encrypted-marker scan below is what stops an
            // encrypted folder opening as a mysteriously empty Library, and treating
            // an unreadable listing as "empty" silently skips it.
            return .unreadable
        }

        for name in contents {
            if name == Self.vaultFileName {
                return .encryptedLibrary
            }
            if Self.sealedExtensions.contains((name as NSString).pathExtension) {
                return .encryptedLibrary
            }
        }

        // An empty folder is deliberately valid: that is how a user starts a
        // fresh Library somewhere.
        return nil
    }
}
