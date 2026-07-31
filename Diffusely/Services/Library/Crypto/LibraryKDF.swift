import Foundation
import CryptoKit
import CommonCrypto

/// Standard, OS-provided key-derivation and encoding helpers used by the
/// Library encryption stack. Pure functions — safe on any thread.
enum LibraryKDF {
    /// PBKDF2-HMAC-SHA256. Used to turn the password / recovery key into a
    /// key-encryption key (KEK). Blocking and deliberately slow — call off the
    /// main actor.
    ///
    /// This is the raw-bytes overload: it accepts the password material as
    /// `Data` directly, so callers deriving from raw recovery-key bytes don't
    /// have to round-trip them through a lossy `String` conversion.
    static func pbkdf2SHA256(passwordData: Data, salt: Data, rounds: UInt32, keyByteCount: Int) -> Data {
        var derived = Data(count: keyByteCount)
        let status = derived.withUnsafeMutableBytes { derivedRaw in
            salt.withUnsafeBytes { saltRaw in
                passwordData.withUnsafeBytes { pwRaw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwRaw.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltRaw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedRaw.bindMemory(to: UInt8.self).baseAddress, keyByteCount
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    /// PBKDF2-HMAC-SHA256 over a UTF-8 encoded password `String`. Delegates
    /// to the `Data`-based overload.
    static func pbkdf2SHA256(password: String, salt: Data, rounds: UInt32, keyByteCount: Int) -> Data {
        pbkdf2SHA256(passwordData: Data(password.utf8), salt: salt, rounds: rounds, keyByteCount: keyByteCount)
    }

    /// HKDF-SHA256 subkey derivation from a master key (the DEK).
    static func hkdfSubkey(from key: SymmetricKey, salt: Data, info: String, byteCount: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: byteCount
        )
    }

    /// Lowercase Base16. Filesystem-safe on case-insensitive volumes.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
