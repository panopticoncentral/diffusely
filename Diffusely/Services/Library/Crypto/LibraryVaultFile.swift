import Foundation
import CryptoKit

enum LibraryVaultError: Error, Equatable { case wrongCredential, malformed }

/// The on-disk `vault.json`. Contains only salts and the DEK wrapped under the
/// password KEK and the recovery KEK. Zero plaintext. `Equatable` for tests.
struct LibraryVaultFile: Codable, Equatable {
    var version: Int
    var kdfRounds: UInt32
    var saltPW: Data
    var wrappedDEKPW: Data
    var saltRecovery: Data
    var wrappedDEKRecovery: Data
}

/// Creates and unlocks a `LibraryVaultFile`. A wrong credential surfaces as a
/// GCM open failure → `.wrongCredential`; there is no separate verifier.
enum LibraryVaultCrypto {
    static let currentVersion = 1

    static func create(password: String, rounds: UInt32) throws -> (file: LibraryVaultFile, dek: SymmetricKey, recoveryKey: String) {
        let dek = SymmetricKey(size: .bits256)
        let recoveryBytes = randomBytes(32)
        let recoveryKey = CrockfordBase32.encodeGrouped(recoveryBytes)

        let saltPW = randomBytes(16)
        let saltRec = randomBytes(16)
        let wrappedPW = try wrap(dek: dek, secret: Data(password.utf8), salt: saltPW, rounds: rounds)
        let wrappedRec = try wrap(dek: dek, secret: recoveryBytes, salt: saltRec, rounds: rounds)

        let file = LibraryVaultFile(
            version: currentVersion, kdfRounds: rounds,
            saltPW: saltPW, wrappedDEKPW: wrappedPW,
            saltRecovery: saltRec, wrappedDEKRecovery: wrappedRec
        )
        return (file, dek, recoveryKey)
    }

    static func unlock(_ file: LibraryVaultFile, password: String) throws -> SymmetricKey {
        try unwrap(file.wrappedDEKPW, secret: Data(password.utf8), salt: file.saltPW, rounds: file.kdfRounds)
    }

    static func unlock(_ file: LibraryVaultFile, recoveryKey: String) throws -> SymmetricKey {
        guard let bytes = CrockfordBase32.decodeGrouped(recoveryKey) else { throw LibraryVaultError.wrongCredential }
        return try unwrap(file.wrappedDEKRecovery, secret: bytes, salt: file.saltRecovery, rounds: file.kdfRounds)
    }

    static func rewrapPassword(_ file: LibraryVaultFile, dek: SymmetricKey, newPassword: String) throws -> LibraryVaultFile {
        let newSalt = randomBytes(16)
        var copy = file
        copy.saltPW = newSalt
        copy.wrappedDEKPW = try wrap(dek: dek, secret: Data(newPassword.utf8), salt: newSalt, rounds: file.kdfRounds)
        return copy
    }

    // MARK: - Wrapping

    /// `secret` is raw key material (UTF-8 password bytes, or raw recovery-key
    /// bytes) — never routed through a `String`, so there is no lossy
    /// re-encoding between derivation and use.
    private static func wrap(dek: SymmetricKey, secret: Data, salt: Data, rounds: UInt32) throws -> Data {
        let kek = SymmetricKey(data: LibraryKDF.pbkdf2SHA256(passwordData: secret, salt: salt, rounds: rounds, keyByteCount: 32))
        let box = try AES.GCM.seal(dek.withUnsafeBytes { Data($0) }, using: kek)
        guard let combined = box.combined else { throw LibraryVaultError.malformed }
        return combined
    }

    private static func unwrap(_ wrapped: Data, secret: Data, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let kek = SymmetricKey(data: LibraryKDF.pbkdf2SHA256(passwordData: secret, salt: salt, rounds: rounds, keyByteCount: 32))
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            return SymmetricKey(data: try AES.GCM.open(box, using: kek))
        } catch {
            throw LibraryVaultError.wrongCredential
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }
}

/// Crockford Base32 (no I/L/O/U) for the human-transcribable recovery key.
enum CrockfordBase32 {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let groupSize = 7

    static func encodeGrouped(_ data: Data) -> String {
        var bits = 0, value = 0, out = ""
        for byte in data {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(alphabet[(value >> (bits - 5)) & 0x1F]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 0x1F]) }
        return stride(from: 0, to: out.count, by: groupSize).map {
            let start = out.index(out.startIndex, offsetBy: $0)
            let end = out.index(start, offsetBy: groupSize, limitedBy: out.endIndex) ?? out.endIndex
            return String(out[start..<end])
        }.joined(separator: "-")
    }

    static func decodeGrouped(_ string: String) -> Data? {
        let clean = string.uppercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        var lookup = [Character: Int]()
        for (i, c) in alphabet.enumerated() { lookup[c] = i }
        var bits = 0, value = 0, bytes = [UInt8]()
        for c in clean {
            guard let v = lookup[c] else { return nil }
            value = (value << 5) | v; bits += 5
            if bits >= 8 { bytes.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        return Data(bytes)
    }
}
