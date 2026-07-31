import Foundation
import CryptoKit

enum LibraryCryptoError: Error { case badEnvelope, authenticationFailed }

/// Encrypts/decrypts individual Library files and derives their opaque
/// on-disk names. Holds the derived subkeys of one DEK; create a fresh
/// instance per unlocked session. Pure/`Sendable` — safe on any thread.
struct LibraryFileCrypto: Sendable {
    /// `.aux(name)` identifies a non-item container file (an album file, the
    /// sort-assistant state) by a stable logical name rather than an itemID.
    enum Role: Sendable, Equatable, Hashable {
        case meta, media, aux(String)

        var label: String {
            switch self {
            case .meta: return "meta"
            case .media: return "media"
            case .aux(let name): return "aux:\(name)"
            }
        }

        var suffix: String {
            switch self {
            case .meta: return "m"
            case .media: return "b"
            case .aux: return "x"
            }
        }
    }

    private static let magic = Data("DFEB".utf8)
    private static let version: UInt8 = 1

    private let contentKey: SymmetricKey
    private let fileKey: SymmetricKey

    init(dek: SymmetricKey) {
        self.contentKey = LibraryKDF.hkdfSubkey(from: dek, salt: Data(), info: "content", byteCount: 32)
        self.fileKey = LibraryKDF.hkdfSubkey(from: dek, salt: Data(), info: "filename", byteCount: 32)
    }

    /// Opaque 128-bit (32 hex char) stem, keyed by `fileKey`. Deterministic so
    /// any call site can compute an item's filename from its id + role.
    func fileToken(itemID: Int, role: Role) -> String {
        let msg = Data("\(role.label):\(itemID)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: fileKey)
        return LibraryKDF.hex(Data(mac).prefix(16))
    }

    func fileName(itemID: Int, role: Role) -> String {
        "\(fileToken(itemID: itemID, role: role)).\(role.suffix)"
    }

    /// Opaque token for a non-item "aux" container file, keyed by its stable
    /// logical name (e.g. "album-<uuid>" or "sort-assistant-state") rather
    /// than an itemID. Mirrors `fileToken(itemID:role:)` for meta/media.
    func fileToken(auxName: String) -> String {
        let msg = Data(Role.aux(auxName).label.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: fileKey)
        return LibraryKDF.hex(Data(mac).prefix(16))
    }

    func fileName(auxName: String) -> String {
        "\(fileToken(auxName: auxName)).\(Role.aux(auxName).suffix)"
    }

    /// `[ "DFEB" | version | AES-GCM combined box ]`. A unique per-file key
    /// (HKDF over the token) means no nonce reuse concern across files.
    func seal(_ plaintext: Data, fileToken: String) throws -> Data {
        let key = perFileKey(fileToken)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw LibraryCryptoError.badEnvelope }
        var out = Self.magic
        out.append(Self.version)
        out.append(combined)
        return out
    }

    func open(_ envelope: Data, fileToken: String) throws -> Data {
        guard envelope.count > 5, envelope.prefix(4) == Self.magic else {
            throw LibraryCryptoError.badEnvelope
        }
        let combined = envelope.subdata(in: 5..<envelope.count)
        let key = perFileKey(fileToken)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw LibraryCryptoError.authenticationFailed
        }
    }

    private func perFileKey(_ token: String) -> SymmetricKey {
        LibraryKDF.hkdfSubkey(from: contentKey, salt: Data(token.utf8), info: "file", byteCount: 32)
    }
}
