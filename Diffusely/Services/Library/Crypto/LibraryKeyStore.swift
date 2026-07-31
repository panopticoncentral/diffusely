import Foundation
import Security
import LocalAuthentication

enum LibraryKeyStoreError: Error { case unexpectedStatus(OSStatus) }

/// Caches the unwrapped DEK for convenience unlocks. The DEK is never persisted
/// anywhere except here; `vault.json` (password/recovery) is the durable path.
protocol LibraryKeyStore: Sendable {
    func store(dek: Data) throws
    func loadWithBiometrics(reason: String) async throws -> Data?
    func clear() throws
}

/// Test double — no OS interaction, no biometric prompt.
final class InMemoryKeyStore: LibraryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func store(dek: Data) throws { lock.withLock { value = dek } }
    func loadWithBiometrics(reason: String) async throws -> Data? { lock.withLock { value } }
    func clear() throws { lock.withLock { value = nil } }
}

/// Biometric-gated Keychain store. Item is device-local and invalidated if the
/// enrolled biometric set changes (`.biometryCurrentSet`).
final class KeychainKeyStore: LibraryKeyStore, @unchecked Sendable {
    private let account = "library.vault.dek"
    private let service = "AchatesSoftware.Diffusely.LibraryVault"

    func store(dek: Data) throws {
        try? clear()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error
        ) else { throw LibraryKeyStoreError.unexpectedStatus(errSecParam) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: dek,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw LibraryKeyStoreError.unexpectedStatus(status) }
    }

    func loadWithBiometrics(reason: String) async throws -> Data? {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound, errSecUserCanceled, errSecAuthFailed: return nil
        default: throw LibraryKeyStoreError.unexpectedStatus(status)
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LibraryKeyStoreError.unexpectedStatus(status)
        }
    }
}
