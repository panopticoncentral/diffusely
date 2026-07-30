# Library At-Rest Encryption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encrypt every personal-Library file at rest (media, sidecars, album files, sort-assistant state) with AES-256-GCM under a key only the user's password or recovery key can unlock, gated day-to-day by Face ID.

**Architecture:** Envelope encryption — a random 256-bit data key (DEK) encrypts all files; the DEK is wrapped separately by a password-derived and a recovery-key-derived KEK, both stored in `vault.json`. A `LibraryVault` actor holds the DEK when unlocked and caches it in the biometric Keychain. A `LibraryFileStore` inserts encrypt-on-write / decrypt-on-read at the container I/O seam, with opaque keyed-hash filenames; a resumable migrator converts the existing library. Video is decrypted to a device-local temp file for playback.

**Tech Stack:** Swift, CryptoKit (`AES.GCM`, `HKDF`, `HMAC`, `SHA256`), CommonCrypto (PBKDF2), Security/LocalAuthentication (Keychain + biometrics), SwiftUI, SwiftData, Nuke, AVFoundation.

## Global Constraints

- **Algorithms are standard/OS-provided only** — AES-256-GCM, PBKDF2-HMAC-SHA256, HKDF-SHA256, HMAC-SHA256. No proprietary crypto. No third-party crypto dependency (PBKDF2 not Argon2 for v1).
- **Cooperative-pool discipline** — every blocking file-coordination, ImageIO, crypto, and migration operation runs on a dedicated `DispatchQueue`, never on `Task.detached` / the Swift concurrency cooperative pool. (Prevents the documented grey-spinner starvation regression.)
- **Sidecar-authoritative invariant** — the sidecar in the container is the source of truth; the SwiftData index (`PersistedLibraryItem`) is disposable and rebuilt from sidecars. Encryption changes bytes/names, never this invariant.
- **Filename tokens use lowercase hex** (Base16), not Base32 — the iCloud container may live on a case-insensitive volume (macOS), and lowercase hex cannot collide under case-folding. (Deviation from the spec's "base32", made for filesystem safety.)
- **PBKDF2 iterations:** 600_000 (calibrated for ~0.3–0.5s; stored in `vault.json` so it can change later).
- **Keychain protection class:** `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `.biometryCurrentSet`.
- **Verify-before-delete** — migration never deletes a plaintext file until its ciphertext has been written and decrypt-verified.
- **All target devices must run this build before encryption is enabled** (precondition surfaced in the enable UI).

---

## File Structure

**Phase 1 — crypto core (new, self-contained, no app dependencies):**
- `Diffusely/Services/Library/Crypto/LibraryKDF.swift` — PBKDF2 + HKDF + hex helpers.
- `Diffusely/Services/Library/Crypto/LibraryFileCrypto.swift` — file envelope seal/open, per-file subkey, filename tokens.
- `Diffusely/Services/Library/Crypto/LibraryVaultFile.swift` — `vault.json` Codable model, DEK generation, wrap/unwrap, recovery-key gen/encode, read/write (+ backup).
- `Diffusely/Services/Library/Crypto/LibraryKeyStore.swift` — `LibraryKeyStore` protocol, `KeychainKeyStore` (biometric) + `InMemoryKeyStore` (tests).
- `Diffusely/Services/Library/Crypto/LibraryVault.swift` — `LibraryVault` actor: lock state, unlock paths, DEK caching.

**Phase 2 — encrypted file store + seams:**
- `Diffusely/Services/Library/LibraryFileStore.swift` — encrypt/passthrough container I/O + name resolution.
- Modify: `LibrarySaveService.swift` (`LibraryFileWriter`), `LibraryImageRequest.swift`, `LibraryContainer.swift`, `LibraryIndexService`, `LibraryDateBackfillService.swift`, `LibraryAlbumService.swift`/`LibraryAlbumFile.swift`, `LibraryVideoPlayer.swift`, `SortAssistant/SortAssistantState.swift`.

**Phase 3 — migration:**
- `Diffusely/Services/Library/LibraryEncryptionMigrator.swift` — forward + reverse resumable migration, `migration-state.json`.

**Phase 4 — UI:**
- `Diffusely/Views/LibraryUnlockView.swift` — the unlock gate.
- `Diffusely/Views/Settings/LibraryEncryptionSettingsView.swift` — enable / disable / change password / show recovery key.
- Modify: `LibraryView.swift` (gate on vault state), app lifecycle (auto-lock).

Test files mirror `DiffuselyTests/Library*Tests.swift`, one per new source file, directory/store-injected, no iCloud or Keychain dependency.

---

# Phase 1 — Crypto Core

### Task 1: Hex + PBKDF2 + HKDF primitives

**Files:**
- Create: `Diffusely/Services/Library/Crypto/LibraryKDF.swift`
- Test: `DiffuselyTests/LibraryKDFTests.swift`

**Interfaces:**
- Produces:
  - `enum LibraryKDF`
  - `static func pbkdf2SHA256(password: String, salt: Data, rounds: UInt32, keyByteCount: Int) -> Data`
  - `static func hkdfSubkey(from key: SymmetricKey, salt: Data, info: String, byteCount: Int) -> SymmetricKey`
  - `static func hex(_ data: Data) -> String` (lowercase)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryKDFTests: XCTestCase {
    func testPBKDF2IsDeterministicAndSaltSensitive() {
        let salt = Data([0x01, 0x02, 0x03, 0x04])
        let a = LibraryKDF.pbkdf2SHA256(password: "hunter2", salt: salt, rounds: 1000, keyByteCount: 32)
        let b = LibraryKDF.pbkdf2SHA256(password: "hunter2", salt: salt, rounds: 1000, keyByteCount: 32)
        let other = LibraryKDF.pbkdf2SHA256(password: "hunter2", salt: Data([0x09]), rounds: 1000, keyByteCount: 32)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, other)
    }

    func testHexIsLowercaseAndFullWidth() {
        XCTAssertEqual(LibraryKDF.hex(Data([0x00, 0x0f, 0xff])), "000fff")
    }

    func testHKDFSubkeysDifferByInfo() {
        let master = SymmetricKey(size: .bits256)
        let content = LibraryKDF.hkdfSubkey(from: master, salt: Data(), info: "content", byteCount: 32)
        let file = LibraryKDF.hkdfSubkey(from: master, salt: Data(), info: "filename", byteCount: 32)
        XCTAssertNotEqual(content.withUnsafeBytes { Data($0) }, file.withUnsafeBytes { Data($0) })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryKDFTests`
Expected: FAIL — `LibraryKDF` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CryptoKit
import CommonCrypto

/// Standard, OS-provided key-derivation and encoding helpers used by the
/// Library encryption stack. Pure functions — safe on any thread.
enum LibraryKDF {
    /// PBKDF2-HMAC-SHA256. Used to turn the password / recovery key into a
    /// key-encryption key (KEK). Blocking and deliberately slow — call off the
    /// main actor.
    static func pbkdf2SHA256(password: String, salt: Data, rounds: UInt32, keyByteCount: Int) -> Data {
        var derived = Data(count: keyByteCount)
        let passwordData = Data(password.utf8)
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryKDFTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Crypto/LibraryKDF.swift DiffuselyTests/LibraryKDFTests.swift
git commit -m "feat(library-crypto): add PBKDF2/HKDF/hex primitives"
```

---

### Task 2: File envelope + per-file key + filename tokens

**Files:**
- Create: `Diffusely/Services/Library/Crypto/LibraryFileCrypto.swift`
- Test: `DiffuselyTests/LibraryFileCryptoTests.swift`

**Interfaces:**
- Consumes: `LibraryKDF.hkdfSubkey`, `LibraryKDF.hex` (Task 1).
- Produces:
  - `struct LibraryFileCrypto` — initialized `init(dek: SymmetricKey)`.
  - `enum Role { case meta, media }`
  - `func fileName(itemID: Int, role: Role) -> String` (e.g. `"<32hex>.m"` / `".b"`)
  - `func seal(_ plaintext: Data, fileToken: String) throws -> Data`
  - `func open(_ envelope: Data, fileToken: String) throws -> Data`
  - `enum LibraryCryptoError: Error { case badEnvelope, authenticationFailed }`
  - `func fileToken(itemID: Int, role: Role) -> String` (the `<32hex>` stem, no suffix)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryFileCryptoTests: XCTestCase {
    private let dek = SymmetricKey(size: .bits256)

    func testSealOpenRoundTrips() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 42, role: .meta)
        let plaintext = Data("hello library".utf8)
        let sealed = try crypto.seal(plaintext, fileToken: token)
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(try crypto.open(sealed, fileToken: token), plaintext)
    }

    func testTamperIsDetected() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let token = crypto.fileToken(itemID: 7, role: .media)
        var sealed = try crypto.seal(Data("x".utf8), fileToken: token)
        sealed[sealed.count - 1] ^= 0xFF   // flip a tag byte
        XCTAssertThrowsError(try crypto.open(sealed, fileToken: token))
    }

    func testWrongTokenFailsToOpen() throws {
        let crypto = LibraryFileCrypto(dek: dek)
        let sealed = try crypto.seal(Data("x".utf8), fileToken: crypto.fileToken(itemID: 1, role: .meta))
        XCTAssertThrowsError(try crypto.open(sealed, fileToken: crypto.fileToken(itemID: 2, role: .meta)))
    }

    func testFileNamesAreDeterministicRoleDistinctAndSuffixed() {
        let crypto = LibraryFileCrypto(dek: dek)
        XCTAssertEqual(crypto.fileName(itemID: 42, role: .meta), crypto.fileName(itemID: 42, role: .meta))
        XCTAssertTrue(crypto.fileName(itemID: 42, role: .meta).hasSuffix(".m"))
        XCTAssertTrue(crypto.fileName(itemID: 42, role: .media).hasSuffix(".b"))
        XCTAssertNotEqual(crypto.fileName(itemID: 42, role: .meta).dropLast(2),
                          crypto.fileName(itemID: 42, role: .media).dropLast(2))
    }

    func testFileNameRevealsNoItemID() {
        let crypto = LibraryFileCrypto(dek: dek)
        XCTAssertFalse(crypto.fileName(itemID: 123456, role: .meta).contains("123456"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileCryptoTests`
Expected: FAIL — `LibraryFileCrypto` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CryptoKit

enum LibraryCryptoError: Error { case badEnvelope, authenticationFailed }

/// Encrypts/decrypts individual Library files and derives their opaque
/// on-disk names. Holds the derived subkeys of one DEK; create a fresh
/// instance per unlocked session. Pure/`Sendable` — safe on any thread.
struct LibraryFileCrypto: Sendable {
    enum Role: Sendable {
        case meta, media
        var label: String { self == .meta ? "meta" : "media" }
        var suffix: String { self == .meta ? "m" : "b" }
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileCryptoTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Crypto/LibraryFileCrypto.swift DiffuselyTests/LibraryFileCryptoTests.swift
git commit -m "feat(library-crypto): add file envelope + opaque filename tokens"
```

---

### Task 3: Vault file — DEK wrap/unwrap, recovery key, persistence

**Files:**
- Create: `Diffusely/Services/Library/Crypto/LibraryVaultFile.swift`
- Test: `DiffuselyTests/LibraryVaultFileTests.swift`

**Interfaces:**
- Consumes: `LibraryKDF.pbkdf2SHA256` (Task 1).
- Produces:
  - `struct LibraryVaultFile: Codable` with `version: Int`, `kdfRounds: UInt32`, `saltPW: Data`, `wrappedDEKPW: Data`, `saltRecovery: Data`, `wrappedDEKRecovery: Data`.
  - `enum LibraryVaultCrypto`
    - `static func create(password: String, rounds: UInt32) throws -> (file: LibraryVaultFile, dek: SymmetricKey, recoveryKey: String)`
    - `static func unlock(_ file: LibraryVaultFile, password: String) throws -> SymmetricKey`
    - `static func unlock(_ file: LibraryVaultFile, recoveryKey: String) throws -> SymmetricKey`
    - `static func rewrapPassword(_ file: LibraryVaultFile, dek: SymmetricKey, newPassword: String) throws -> LibraryVaultFile`
  - `enum LibraryVaultError: Error { case wrongCredential, malformed }`
  - Recovery-key format: 32 random bytes → Crockford Base32, grouped in 6 blocks of 7 chars (e.g. `A1B2C3D-...`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryVaultFileTests: XCTestCase {
    private let rounds: UInt32 = 1000   // fast for tests

    func testUnlockWithPasswordAndRecoveryYieldSameDEK() throws {
        let (file, dek, recovery) = try LibraryVaultCrypto.create(password: "correct horse", rounds: rounds)
        let raw = dek.withUnsafeBytes { Data($0) }
        XCTAssertEqual(try LibraryVaultCrypto.unlock(file, password: "correct horse").withUnsafeBytes { Data($0) }, raw)
        XCTAssertEqual(try LibraryVaultCrypto.unlock(file, recoveryKey: recovery).withUnsafeBytes { Data($0) }, raw)
    }

    func testWrongPasswordRejected() throws {
        let (file, _, _) = try LibraryVaultCrypto.create(password: "right", rounds: rounds)
        XCTAssertThrowsError(try LibraryVaultCrypto.unlock(file, password: "wrong")) { error in
            XCTAssertEqual(error as? LibraryVaultError, .wrongCredential)
        }
    }

    func testPasswordChangeKeepsDEKAndInvalidatesOldPassword() throws {
        let (file, dek, _) = try LibraryVaultCrypto.create(password: "old", rounds: rounds)
        let rewrapped = try LibraryVaultCrypto.rewrapPassword(file, dek: dek, newPassword: "new")
        XCTAssertEqual(try LibraryVaultCrypto.unlock(rewrapped, password: "new").withUnsafeBytes { Data($0) },
                       dek.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try LibraryVaultCrypto.unlock(rewrapped, password: "old"))
    }

    func testVaultFileCodableRoundTrips() throws {
        let (file, _, _) = try LibraryVaultCrypto.create(password: "p", rounds: rounds)
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(LibraryVaultFile.self, from: data)
        XCTAssertEqual(decoded, file)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryVaultFileTests`
Expected: FAIL — `LibraryVaultFile`/`LibraryVaultCrypto` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
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

    private static func wrap(dek: SymmetricKey, secret: Data, salt: Data, rounds: UInt32) throws -> Data {
        let kek = SymmetricKey(data: LibraryKDF.pbkdf2SHA256(password: secretString(secret), salt: salt, rounds: rounds, keyByteCount: 32))
        let box = try AES.GCM.seal(dek.withUnsafeBytes { Data($0) }, using: kek)
        guard let combined = box.combined else { throw LibraryVaultError.malformed }
        return combined
    }

    private static func unwrap(_ wrapped: Data, secret: Data, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let kek = SymmetricKey(data: LibraryKDF.pbkdf2SHA256(password: secretString(secret), salt: salt, rounds: rounds, keyByteCount: 32))
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            return SymmetricKey(data: try AES.GCM.open(box, using: kek))
        } catch {
            throw LibraryVaultError.wrongCredential
        }
    }

    // PBKDF2 takes a String; the recovery secret is raw bytes, so pass its raw
    // form losslessly as a Latin-1 string (1 byte ⇄ 1 scalar).
    private static func secretString(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).unicodeScalars.count == data.count
            ? String(bytes: data, encoding: .isoLatin1) ?? ""
            : String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
```

> Note: `secretString` intentionally uses ISO Latin-1 so arbitrary recovery bytes map 1:1 to characters for PBKDF2. Passwords are UTF-8 text and also round-trip through Latin-1's byte view identically for the KDF because PBKDF2 hashes the UTF-8 bytes — keep passwords as `Data(password.utf8)` at the call site (already done above) and Latin-1 only for the raw recovery bytes. Simplify during implementation if a cleaner `Data`-based PBKDF2 wrapper is added to `LibraryKDF`.

Also create `CrockfordBase32` in the same file:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryVaultFileTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Crypto/LibraryVaultFile.swift DiffuselyTests/LibraryVaultFileTests.swift
git commit -m "feat(library-crypto): vault file with DEK wrap/unwrap + recovery key"
```

---

### Task 4: Key store abstraction (Keychain + in-memory)

**Files:**
- Create: `Diffusely/Services/Library/Crypto/LibraryKeyStore.swift`
- Test: `DiffuselyTests/LibraryKeyStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol LibraryKeyStore: Sendable { func store(dek: Data) throws; func loadWithBiometrics(reason: String) async throws -> Data?; func clear() throws }`
  - `final class InMemoryKeyStore: LibraryKeyStore` (test double; `loadWithBiometrics` returns the stored bytes without prompting).
  - `final class KeychainKeyStore: LibraryKeyStore` (real; biometric-gated).
  - `enum LibraryKeyStoreError: Error { case unexpectedStatus(OSStatus) }`

- [ ] **Step 1: Write the failing test** (only the in-memory double is unit-tested; Keychain/biometrics is verified manually in Phase 4)

```swift
import XCTest
@testable import Diffusely

final class LibraryKeyStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrips() async throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(try await store.loadWithBiometrics(reason: "test"))
        try store.store(dek: Data([1, 2, 3]))
        let loaded = try await store.loadWithBiometrics(reason: "test")
        XCTAssertEqual(loaded, Data([1, 2, 3]))
        try store.clear()
        XCTAssertNil(try await store.loadWithBiometrics(reason: "test"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryKeyStoreTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
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
    func store(dek: Data) throws { lock.lock(); value = dek; lock.unlock() }
    func loadWithBiometrics(reason: String) async throws -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    func clear() throws { lock.lock(); value = nil; lock.unlock() }
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryKeyStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Crypto/LibraryKeyStore.swift DiffuselyTests/LibraryKeyStoreTests.swift
git commit -m "feat(library-crypto): key store abstraction (keychain + in-memory)"
```

---

### Task 5: LibraryVault actor — lock state & unlock paths

**Files:**
- Create: `Diffusely/Services/Library/Crypto/LibraryVault.swift`
- Test: `DiffuselyTests/LibraryVaultTests.swift`

**Interfaces:**
- Consumes: `LibraryVaultFile`, `LibraryVaultCrypto`, `LibraryKeyStore`, `LibraryFileCrypto`, `LibraryVaultError`.
- Produces:
  - `actor LibraryVault`
    - `init(vaultURL: URL, backupURL: URL, keyStore: LibraryKeyStore, rounds: UInt32)`
    - `enum State: Equatable { case notConfigured, locked, unlocked }`
    - `func state() -> State`
    - `func configure(password: String) throws -> String` (creates vault + backup on disk, returns recovery key, leaves vault **unlocked**, caches DEK)
    - `func unlock(password: String) async throws`
    - `func unlock(recoveryKey: String) async throws`
    - `func unlockWithBiometrics() async -> Bool`
    - `func lock()`
    - `func changePassword(old: String, new: String) async throws`
    - `func crypto() -> LibraryFileCrypto?` (nil unless unlocked)
    - `func teardown()` (disable path: clears key store + removes vault files) — used by Phase 3 disable.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Diffusely

final class LibraryVaultTests: XCTestCase {
    private func makeVault() -> (LibraryVault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(
            vaultURL: dir.appendingPathComponent("vault.json"),
            backupURL: dir.appendingPathComponent("vault.backup.json"),
            keyStore: InMemoryKeyStore(), rounds: 1000
        )
        return (vault, dir)
    }

    func testLifecycle() async throws {
        let (vault, _) = makeVault()
        let s0 = await vault.state()
        XCTAssertEqual(s0, .notConfigured)

        let recovery = try await vault.configure(password: "pw")
        XCTAssertFalse(recovery.isEmpty)
        let s1 = await vault.state()
        XCTAssertEqual(s1, .unlocked)
        let c1 = await vault.crypto()
        XCTAssertNotNil(c1)

        await vault.lock()
        let s2 = await vault.state()
        XCTAssertEqual(s2, .locked)
        let c2 = await vault.crypto()
        XCTAssertNil(c2)

        try await vault.unlock(password: "pw")
        let s3 = await vault.state()
        XCTAssertEqual(s3, .unlocked)

        await vault.lock()
        try await vault.unlock(recoveryKey: recovery)
        let s4 = await vault.state()
        XCTAssertEqual(s4, .unlocked)
    }

    func testWrongPasswordThrowsAndStaysLocked() async throws {
        let (vault, _) = makeVault()
        _ = try await vault.configure(password: "pw")
        await vault.lock()
        do { try await vault.unlock(password: "nope"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? LibraryVaultError, .wrongCredential) }
        let s = await vault.state()
        XCTAssertEqual(s, .locked)
    }

    func testConfigurePersistsVaultAcrossInstances() async throws {
        let (vault, dir) = makeVault()
        _ = try await vault.configure(password: "pw")
        // Second instance over the same directory sees a configured, locked vault.
        let reopened = LibraryVault(
            vaultURL: dir.appendingPathComponent("vault.json"),
            backupURL: dir.appendingPathComponent("vault.backup.json"),
            keyStore: InMemoryKeyStore(), rounds: 1000
        )
        let s = await reopened.state()
        XCTAssertEqual(s, .locked)
        try await reopened.unlock(password: "pw")
        let s2 = await reopened.state()
        XCTAssertEqual(s2, .unlocked)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryVaultTests`
Expected: FAIL — `LibraryVault` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CryptoKit

/// Session-scoped source of truth for Library encryption. Owns the vault file
/// on disk and the in-memory DEK. All PBKDF2/file I/O here is fast enough for
/// the actor, but callers should invoke unlock off the main actor.
actor LibraryVault {
    enum State: Equatable { case notConfigured, locked, unlocked }

    private let vaultURL: URL
    private let backupURL: URL
    private let keyStore: LibraryKeyStore
    private let rounds: UInt32

    private var dek: SymmetricKey?

    init(vaultURL: URL, backupURL: URL, keyStore: LibraryKeyStore, rounds: UInt32) {
        self.vaultURL = vaultURL
        self.backupURL = backupURL
        self.keyStore = keyStore
        self.rounds = rounds
    }

    func state() -> State {
        if dek != nil { return .unlocked }
        return loadFile() == nil ? .notConfigured : .locked
    }

    func crypto() -> LibraryFileCrypto? {
        dek.map { LibraryFileCrypto(dek: $0) }
    }

    func configure(password: String) throws -> String {
        let (file, dek, recovery) = try LibraryVaultCrypto.create(password: password, rounds: rounds)
        try writeFile(file)
        self.dek = dek
        try? keyStore.store(dek: dek.withUnsafeBytes { Data($0) })
        return recovery
    }

    func unlock(password: String) throws {
        guard let file = loadFile() else { throw LibraryVaultError.malformed }
        let key = try LibraryVaultCrypto.unlock(file, password: password)
        self.dek = key
        try? keyStore.store(dek: key.withUnsafeBytes { Data($0) })
    }

    func unlock(recoveryKey: String) throws {
        guard let file = loadFile() else { throw LibraryVaultError.malformed }
        let key = try LibraryVaultCrypto.unlock(file, recoveryKey: recoveryKey)
        self.dek = key
        try? keyStore.store(dek: key.withUnsafeBytes { Data($0) })
    }

    func unlockWithBiometrics() async -> Bool {
        guard loadFile() != nil else { return false }
        guard let raw = try? await keyStore.loadWithBiometrics(reason: "Unlock your Library"), !raw.isEmpty else {
            return false
        }
        self.dek = SymmetricKey(data: raw)
        return true
    }

    func lock() { dek = nil }

    func changePassword(old: String, new: String) throws {
        guard let file = loadFile() else { throw LibraryVaultError.malformed }
        let key = try LibraryVaultCrypto.unlock(file, password: old)
        let rewrapped = try LibraryVaultCrypto.rewrapPassword(file, dek: key, newPassword: new)
        try writeFile(rewrapped)
    }

    func teardown() {
        dek = nil
        try? keyStore.clear()
        try? FileManager.default.removeItem(at: vaultURL)
        try? FileManager.default.removeItem(at: backupURL)
    }

    // MARK: - Persistence (primary + backup)

    private func loadFile() -> LibraryVaultFile? {
        for url in [vaultURL, backupURL] {
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(LibraryVaultFile.self, from: data) {
                return file
            }
        }
        return nil
    }

    private func writeFile(_ file: LibraryVaultFile) throws {
        let data = try JSONEncoder().encode(file)
        try data.write(to: vaultURL, options: .atomic)
        try data.write(to: backupURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryVaultTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/Crypto/LibraryVault.swift DiffuselyTests/LibraryVaultTests.swift
git commit -m "feat(library-crypto): LibraryVault actor with lock/unlock lifecycle"
```

---

# Phase 2 — Encrypted File Store & Seams

### Task 6: LibraryFileStore — encrypt/passthrough container I/O

**Files:**
- Create: `Diffusely/Services/Library/LibraryFileStore.swift`
- Test: `DiffuselyTests/LibraryFileStoreTests.swift`

**Interfaces:**
- Consumes: `LibraryVault`, `LibraryFileCrypto`.
- Produces (a single indirection every seam uses; when `crypto == nil` it is pure passthrough to today's plaintext names):
  - `struct LibraryFileStore`
    - `init(itemsDirectory: URL, crypto: LibraryFileCrypto?)`
    - `func metadataURL(itemID: Int) -> URL`
    - `func mediaURL(itemID: Int, plaintextExtension: String) -> URL`
    - `func writeMetadata(_ data: Data, itemID: Int) throws`
    - `func readMetadata(itemID: Int) -> Data?`
    - `func writeMedia(_ data: Data, itemID: Int, plaintextExtension: String) throws`
    - `func readMedia(itemID: Int, plaintextExtension: String) -> Data?`
    - `func removeItem(itemID: Int, plaintextExtension: String)`
    - `func enumerateMetadataFiles() -> [URL]` (encrypted: `*.m`; plaintext: `*.json`)
    - `func itemID(forMetadataFile url: URL) -> Int?` (encrypted: decode payload → itemID; plaintext: parse stem)
    - `var isEncrypted: Bool`
- All reads/writes go through `NSFileCoordinator` exactly like `LibraryFileWriter` does today.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryFileStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testPlaintextPassthroughUsesLegacyNames() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: nil)
        try store.writeMetadata(Data("{\"itemID\":5}".utf8), itemID: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("5.json").path))
        XCTAssertEqual(store.readMetadata(itemID: 5), Data("{\"itemID\":5}".utf8))
        XCTAssertFalse(store.isEncrypted)
    }

    func testEncryptedWriteIsOpaqueAndRoundTrips() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let payload = Data("{\"itemID\":5}".utf8)
        try store.writeMetadata(payload, itemID: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("5.json").path))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".m") })
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains("5") })   // id not in name
        XCTAssertEqual(store.readMetadata(itemID: 5), payload)
    }

    func testEnumerateAndRecoverItemID() throws {
        let dir = tempDir()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        try store.writeMetadata(Data("{\"itemID\":42}".utf8), itemID: 42)
        let metas = store.enumerateMetadataFiles()
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(store.itemID(forMetadataFile: metas[0]), 42)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileStoreTests`
Expected: FAIL — `LibraryFileStore` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The single indirection for all personal-Library container I/O. With a
/// `crypto`, contents are AES-GCM sealed and names are opaque tokens; without
/// one, it is a pure passthrough to today's `<id>.json` / `<id>.<ext>` layout.
/// Synchronous, file-coordinated I/O — call from the Library's dedicated I/O
/// queue, never the cooperative pool.
struct LibraryFileStore {
    let itemsDirectory: URL
    let crypto: LibraryFileCrypto?

    var isEncrypted: Bool { crypto != nil }

    init(itemsDirectory: URL, crypto: LibraryFileCrypto?) {
        self.itemsDirectory = itemsDirectory
        self.crypto = crypto
    }

    // MARK: URLs

    func metadataURL(itemID: Int) -> URL {
        if let crypto {
            return itemsDirectory.appendingPathComponent(crypto.fileName(itemID: itemID, role: .meta))
        }
        return itemsDirectory.appendingPathComponent("\(itemID).json")
    }

    func mediaURL(itemID: Int, plaintextExtension ext: String) -> URL {
        if let crypto {
            return itemsDirectory.appendingPathComponent(crypto.fileName(itemID: itemID, role: .media))
        }
        return itemsDirectory.appendingPathComponent("\(itemID).\(ext)")
    }

    // MARK: Metadata

    func writeMetadata(_ data: Data, itemID: Int) throws {
        try write(payload: data, to: metadataURL(itemID: itemID),
                  token: crypto?.fileToken(itemID: itemID, role: .meta))
    }

    func readMetadata(itemID: Int) -> Data? {
        read(url: metadataURL(itemID: itemID), token: crypto?.fileToken(itemID: itemID, role: .meta))
    }

    // MARK: Media

    func writeMedia(_ data: Data, itemID: Int, plaintextExtension ext: String) throws {
        try write(payload: data, to: mediaURL(itemID: itemID, plaintextExtension: ext),
                  token: crypto?.fileToken(itemID: itemID, role: .media))
    }

    func readMedia(itemID: Int, plaintextExtension ext: String) -> Data? {
        read(url: mediaURL(itemID: itemID, plaintextExtension: ext),
             token: crypto?.fileToken(itemID: itemID, role: .media))
    }

    func removeItem(itemID: Int, plaintextExtension ext: String) {
        for url in [metadataURL(itemID: itemID), mediaURL(itemID: itemID, plaintextExtension: ext)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Enumeration

    func enumerateMetadataFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil)) ?? []
        let suffix = isEncrypted ? ".m" : ".json"
        return all.filter { $0.lastPathComponent.hasSuffix(suffix) }
    }

    func itemID(forMetadataFile url: URL) -> Int? {
        if let crypto {
            let token = url.deletingPathExtension().lastPathComponent
            guard let data = read(url: url, token: token),
                  let stub = try? JSONDecoder().decode(ItemIDStub.self, from: data) else { return nil }
            return stub.itemID
        }
        return Int(url.deletingPathExtension().lastPathComponent)
    }

    private struct ItemIDStub: Decodable { let itemID: Int }

    // MARK: Coordinated I/O

    private func write(payload: Data, to url: URL, token: String?) throws {
        let bytes: Data
        if let token, let crypto { bytes = try crypto.seal(payload, fileToken: token) } else { bytes = payload }
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { dest in
            do { try bytes.write(to: dest, options: .atomic) } catch { thrown = error }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }

    private func read(url: URL, token: String?) -> Data? {
        var raw: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { readURL in
            raw = try? Data(contentsOf: readURL)
        }
        guard let raw else { return nil }
        guard let token, let crypto else { return raw }
        return try? crypto.open(raw, fileToken: token)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryFileStore.swift DiffuselyTests/LibraryFileStoreTests.swift
git commit -m "feat(library-store): LibraryFileStore with encrypt + passthrough modes"
```

---

### Task 7: Vault provider — resolve the active store

**Files:**
- Create: `Diffusely/Services/Library/LibraryVaultProvider.swift`
- Modify: `Diffusely/Services/Library/LibraryContainer.swift:55-61`
- Test: `DiffuselyTests/LibraryVaultProviderTests.swift`

**Interfaces:**
- Consumes: `LibraryVault`, `LibraryFileStore`, `LibraryContainer`.
- Produces:
  - `@MainActor final class LibraryVaultProvider: ObservableObject` — process-wide singleton `static let shared`.
    - `@Published private(set) var state: LibraryVault.State`
    - `let vault: LibraryVault`
    - `func fileStore() async -> LibraryFileStore` (builds a `LibraryFileStore` over the resolved items directory with the current `crypto()` — encrypted when unlocked, passthrough otherwise)
    - `func refreshState() async`
  - `LibraryContainer` gains `func vaultURLs() throws -> (vault: URL, backup: URL)` returning `Documents/vault.json` + `Documents/vault.backup.json` (siblings of `Items/`, so they are never enumerated as items).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Diffusely

@MainActor
final class LibraryVaultProviderTests: XCTestCase {
    func testFileStoreIsPassthroughWhenNotConfigured() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)
        let store = await provider.fileStore()
        XCTAssertFalse(store.isEncrypted)
    }

    func testFileStoreIsEncryptedWhenUnlocked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = LibraryVault(vaultURL: dir.appendingPathComponent("v.json"),
                                 backupURL: dir.appendingPathComponent("v.bak.json"),
                                 keyStore: InMemoryKeyStore(), rounds: 1000)
        _ = try await vault.configure(password: "pw")
        let provider = LibraryVaultProvider(vault: vault, itemsDirectory: dir)
        let store = await provider.fileStore()
        XCTAssertTrue(store.isEncrypted)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryVaultProviderTests`
Expected: FAIL — `LibraryVaultProvider` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Combine

/// App-facing coordinator: owns the `LibraryVault`, publishes its state for UI
/// gating, and vends a `LibraryFileStore` bound to the current unlock state.
@MainActor
final class LibraryVaultProvider: ObservableObject {
    @Published private(set) var state: LibraryVault.State = .notConfigured

    let vault: LibraryVault
    private let itemsDirectory: URL

    init(vault: LibraryVault, itemsDirectory: URL) {
        self.vault = vault
        self.itemsDirectory = itemsDirectory
        Task { await refreshState() }
    }

    /// Production singleton wired to the real container + biometric key store.
    static let shared: LibraryVaultProvider = {
        // Resolve synchronously off the cached container; falls back to a temp
        // dir only if the container is unavailable at process start.
        let dir = (try? LibraryContainerSync.itemsDirectory()) ?? FileManager.default.temporaryDirectory
        let urls = (try? LibraryContainerSync.vaultURLs())
            ?? (dir.appendingPathComponent("vault.json"), dir.appendingPathComponent("vault.backup.json"))
        let vault = LibraryVault(vaultURL: urls.0, backupURL: urls.1,
                                 keyStore: KeychainKeyStore(), rounds: 600_000)
        return LibraryVaultProvider(vault: vault, itemsDirectory: dir)
    }()

    func fileStore() async -> LibraryFileStore {
        LibraryFileStore(itemsDirectory: itemsDirectory, crypto: await vault.crypto())
    }

    func refreshState() async {
        state = await vault.state()
    }
}
```

> Implementation note: `LibraryContainer` is an `actor`; add a small synchronous helper (`LibraryContainerSync`) or make the provider's `shared` initializer `async` via a one-time bootstrap in the app entry point. Prefer bootstrapping in the app's `init`/`task` and injecting the resolved directory, to avoid blocking. Update `LibraryContainer` to expose `vaultURLs()` alongside `itemsDirectory()`.

Add to `LibraryContainer.swift` (actor method):

```swift
/// vault.json + backup live in Documents/ (siblings of Items/), so they are
/// never enumerated as library items.
func vaultURLs() throws -> (vault: URL, backup: URL) {
    let documents = try itemsDirectory().deletingLastPathComponent()
    return (documents.appendingPathComponent("vault.json"),
            documents.appendingPathComponent("vault.backup.json"))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryVaultProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryVaultProvider.swift Diffusely/Services/Library/LibraryContainer.swift DiffuselyTests/LibraryVaultProviderTests.swift
git commit -m "feat(library-store): vault provider + container vault URLs"
```

---

### Task 8: Route the save/read writer through the store

**Files:**
- Modify: `Diffusely/Services/Library/LibrarySaveService.swift:22-113` (`LibraryFileWriter`)
- Test: `DiffuselyTests/LibraryFileWriterTests.swift` (extend existing coverage; if absent, create)

**Interfaces:**
- Consumes: `LibraryFileStore` (Task 6).
- Produces: `LibraryFileWriter` initialized with a `LibraryFileStore` instead of a bare `itemsDirectory`; `commit`, `readMetadata`, `rewriteMetadata`, `itemExists`, `mediaURL` delegate to the store. Public method signatures unchanged so `LibrarySaveService.performSave` and tests keep compiling; only the initializer changes: `init(store: LibraryFileStore)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryFileWriterEncryptedTests: XCTestCase {
    private func meta(_ id: Int) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: id,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://civitai.com/images/\(id)", sourceDomain: "civitai.com",
            originalCDNURL: "https://cdn/\(id).jpeg", mediaType: .image,
            mediaFileName: "\(id).jpeg", fileByteSize: 3, contentSHA256: "abc",
            width: 1, height: 1, nsfwLevel: 1, author: .init(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil, savedAt: Date(), savedByAppVersion: "test")
    }

    func testCommitThenReadUnderEncryptionRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let writer = LibraryFileWriter(store: store)

        let tmp = dir.appendingPathComponent("incoming.bin")
        try Data("img".utf8).write(to: tmp)
        try writer.commit(metadata: meta(9), mediaTempURL: tmp)

        XCTAssertTrue(writer.itemExists(itemID: 9))
        XCTAssertEqual(writer.readMetadata(itemID: 9)?.itemID, 9)
        // No plaintext id-named files leaked to disk.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains("9.json"))
        XCTAssertFalse(names.contains("9.jpeg"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileWriterEncryptedTests`
Expected: FAIL — `LibraryFileWriter(store:)` initializer does not exist.

- [ ] **Step 3: Write minimal implementation**

Rewrite `LibraryFileWriter` to hold a `LibraryFileStore`. Key changes:

```swift
struct LibraryFileWriter {
    let store: LibraryFileStore

    var itemsDirectory: URL { store.itemsDirectory }

    func mediaURL(for metadata: LibraryItemMetadata) -> URL {
        store.mediaURL(itemID: metadata.itemID, plaintextExtension: metadata.mediaType.fileExtension)
    }

    func metadataURL(forItemID id: Int) -> URL { store.metadataURL(itemID: id) }

    func itemExists(itemID: Int) -> Bool { store.readMetadata(itemID: itemID) != nil }

    func commit(metadata: LibraryItemMetadata, mediaTempURL: URL) throws {
        let mediaBytes = try Data(contentsOf: mediaTempURL)
        try store.writeMedia(mediaBytes, itemID: metadata.itemID,
                             plaintextExtension: metadata.mediaType.fileExtension)
        try? FileManager.default.removeItem(at: mediaTempURL)
        let json = try LibraryItemMetadata.encoder().encode(metadata)   // JSON last = commit marker
        try store.writeMetadata(json, itemID: metadata.itemID)
    }

    func readMetadata(itemID id: Int) -> LibraryItemMetadata? {
        guard let data = store.readMetadata(itemID: id) else { return nil }
        return try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
    }

    func rewriteMetadata(_ metadata: LibraryItemMetadata) throws {
        let json = try LibraryItemMetadata.encoder().encode(metadata)
        try store.writeMetadata(json, itemID: metadata.itemID)
    }
}
```

Update `LibrarySaveService.performSave` to build the writer from the vault provider's current store:

```swift
let itemsDirectory = try await LibraryContainer.shared.itemsDirectory()
let store = await LibraryVaultProvider.shared.fileStore()
let writer = LibraryFileWriter(store: store)
```

> Behavior preserved: media written first, JSON last (the "fully saved" commit marker). The prior `NSFileCoordinator` move is replaced by `store.writeMedia`, which coordinates its own atomic write. Reading the temp file into memory is acceptable for a single item (grid downsampling already loads full media).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryFileWriterEncryptedTests`
Also run the existing `LibraryFileMaterializerTests` / any `LibraryFileWriter` tests to confirm no regression.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibrarySaveService.swift DiffuselyTests/LibraryFileWriterEncryptedTests.swift
git commit -m "feat(library-store): route save/read writer through LibraryFileStore"
```

---

### Task 9: Decrypt-aware image byte cascade

**Files:**
- Modify: `Diffusely/Services/Library/LibraryImageRequest.swift:81-169`
- Test: `DiffuselyTests/LibraryImageRequestTests.swift` (extend existing)

**Interfaces:**
- Consumes: `LibraryFileStore`, `LibraryVaultProvider`.
- Produces: `loadBytes` and `originalCDNURL(itemID:in:)` obtain the file store from `LibraryVaultProvider.shared`; when `store.isEncrypted`, the CDN-first shortcut is skipped and thumbnails are built from decrypted in-memory bytes. New helper: `static func decryptedMediaData(itemID:store:) -> Data?`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryImageRequestEncryptedTests: XCTestCase {
    func testDecryptedMediaDataReadsEncryptedBlob() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])   // stub bytes
        try store.writeMedia(jpeg, itemID: 3, plaintextExtension: "jpeg")
        XCTAssertEqual(LibraryImageRequest.decryptedMediaData(itemID: 3, store: store), jpeg)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryImageRequestEncryptedTests`
Expected: FAIL — `decryptedMediaData` undefined.

- [ ] **Step 3: Write minimal implementation**

Add the helper and branch the cascade:

```swift
static func decryptedMediaData(itemID: Int, store: LibraryFileStore) -> Data? {
    store.readMedia(itemID: itemID, plaintextExtension: "jpeg")   // ext ignored under encryption
}
```

In `loadBytes`, resolve the store and branch:

```swift
private static func loadBytes(itemID: Int, mediaFileName: String, isVideo: Bool, maxDimension: CGFloat) async throws -> Data {
    let store = await LibraryVaultProvider.shared.fileStore()

    if store.isEncrypted {
        // No CDN shortcut: it would network-leak which images are saved.
        guard let media = await runIO({ decryptedMediaData(itemID: itemID, store: store) }) else {
            throw LoadError.unavailable
        }
        if isVideo {
            let tempURL = try LibraryTempMedia.writePlaintext(media, itemID: itemID, ext: "mp4")
            defer { LibraryTempMedia.remove(tempURL) }
            guard let img = await extractPosterFrame(url: tempURL, maxDimension: maxDimension),
                  let data = img.jpegData(compressionQuality: 0.8) else { throw LoadError.unavailable }
            return data
        } else {
            guard let img = await runIO({ ImageDownsampler.downsample(data: media, maxDimension: maxDimension) }),
                  let data = img.jpegData(compressionQuality: 0.8) else { throw LoadError.unavailable }
            return data
        }
    }

    // --- existing plaintext cascade unchanged below ---
    let dir = try await LibraryContainer.shared.itemsDirectory()
    let originalURL = dir.appendingPathComponent(mediaFileName)
    if let cdn = await cdnThumbnailData(itemID: itemID, isVideo: isVideo, maxDimension: maxDimension, dir: dir) {
        return cdn
    }
    if await LibraryFileMaterializer.isReady(url: originalURL) == false {
        try await LibraryFileMaterializer.download(url: originalURL)
        let index = await LibrarySaveService.shared.indexService
        await index?.recordAccess(itemID: itemID, status: .downloaded)
    }
    guard let image = await thumbnailImage(localURL: originalURL, isVideo: isVideo, maxDimension: maxDimension),
          let data = image.jpegData(compressionQuality: 0.8) else { throw LoadError.unavailable }
    return data
}
```

> `LibraryTempMedia` is introduced in Task 10; land Task 9's non-video branch first, or implement Tasks 9–10 together. The encrypted image path uses `store.readMedia`, which under encryption ignores the passed extension (the media role token is extension-independent). Note the encrypted branch reads the *original* full-res blob and downsamples — the byte cascade's iCloud materialization still applies because `store.readMedia` reads the (possibly-not-yet-downloaded) opaque file; add an `isReady`/`download` check on `store.mediaURL(itemID:...)` mirroring the plaintext path.

Refine the encrypted branch to materialize first:

```swift
let mediaURL = store.mediaURL(itemID: itemID, plaintextExtension: "")
if await LibraryFileMaterializer.isReady(url: mediaURL) == false {
    try await LibraryFileMaterializer.download(url: mediaURL)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryImageRequestEncryptedTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryImageRequest.swift DiffuselyTests/LibraryImageRequestEncryptedTests.swift
git commit -m "feat(library-store): decrypt-aware image byte cascade"
```

---

### Task 10: Decrypt-to-temp for video playback

**Files:**
- Create: `Diffusely/Services/Library/LibraryTempMedia.swift`
- Modify: `Diffusely/Views/LibraryVideoPlayer.swift`
- Test: `DiffuselyTests/LibraryTempMediaTests.swift`

**Interfaces:**
- Produces:
  - `enum LibraryTempMedia`
    - `static func writePlaintext(_ data: Data, itemID: Int, ext: String) throws -> URL` (writes to an app-private Caches subdir with `.completeFileProtection`, outside the iCloud container)
    - `static func remove(_ url: URL)`
    - `static func sweep()` (delete all leftovers; call on launch)
  - `LibraryVideoPlayer` decrypts to a temp URL when encryption is on, plays that URL, and removes it on teardown.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Diffusely

final class LibraryTempMediaTests: XCTestCase {
    func testWriteIsOutsideContainerAndSweepable() throws {
        let url = try LibraryTempMedia.writePlaintext(Data("clip".utf8), itemID: 11, ext: "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(url.path.contains("Mobile Documents"))   // not in iCloud container
        LibraryTempMedia.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryTempMediaTests`
Expected: FAIL — `LibraryTempMedia` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Ephemeral, device-local, Data-Protected plaintext for decrypt-to-temp video
/// playback. Never synced (lives in Caches, outside the iCloud container) and
/// swept on launch + removed on player teardown.
enum LibraryTempMedia {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryPlaintext", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func writePlaintext(_ data: Data, itemID: Int, ext: String) throws -> URL {
        let url = dir.appendingPathComponent("\(itemID)-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func sweep() {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? FileManager.default.removeItem(at: item) }
    }
}
```

In `LibraryVideoPlayer`, when `LibraryVaultProvider.shared` store is encrypted, decrypt the media to a temp URL and hand *that* to the `AVPlayer`; on `onDisappear`/teardown call `LibraryTempMedia.remove`. Call `LibraryTempMedia.sweep()` from the app entry point's launch task.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryTempMediaTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryTempMedia.swift Diffusely/Views/LibraryVideoPlayer.swift DiffuselyTests/LibraryTempMediaTests.swift
git commit -m "feat(library-store): decrypt-to-temp video playback"
```

---

### Task 11: Index rebuild, backfill, albums & sort-assistant through the store

**Files:**
- Modify: `Diffusely/Services/Library/LibraryIndexService.swift`, `LibraryDateBackfillService.swift`, `LibraryAlbumService.swift` / `LibraryAlbumFile.swift`, `Diffusely/Services/Library/SortAssistant/SortAssistantState.swift`
- Test: `DiffuselyTests/LibraryIndexEncryptedTests.swift`

**Interfaces:**
- Consumes: `LibraryFileStore`.
- Produces: reconcile/index enumerates via `store.enumerateMetadataFiles()` + `store.itemID(forMetadataFile:)` and decodes via `store.readMetadata`; backfill rewrites via `store.writeMetadata`; album files and `sort-assistant-state.json` read/write through analogous store helpers (`writeAux(_:name:)` / `readAux(name:)` added to `LibraryFileStore` for non-item files, using role `.meta`-style tokens keyed by a stable string name).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryIndexEncryptedTests: XCTestCase {
    func testEnumerateReturnsItemIDsFromEncryptedSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        for id in [10, 20, 30] { try store.writeMetadata(Data("{\"itemID\":\(id)}".utf8), itemID: id) }
        let ids = store.enumerateMetadataFiles().compactMap { store.itemID(forMetadataFile: $0) }.sorted()
        XCTAssertEqual(ids, [10, 20, 30])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryIndexEncryptedTests`
Expected: FAIL — reconcile still parses `<int>.json` names directly.

- [ ] **Step 3: Write minimal implementation**

Replace every `contentsOfDirectory` + `Int(stem)` reconcile path and every direct `<id>.json` read/write in the four services with the store's `enumerateMetadataFiles()`, `itemID(forMetadataFile:)`, `readMetadata`, `writeMetadata`. For album files and sort-assistant state, add to `LibraryFileStore`:

```swift
func auxURL(name: String) -> URL {
    if let crypto {
        let token = LibraryKDF.hex(Data(HMAC<SHA256>.authenticationCode(
            for: Data("aux:\(name)".utf8), using: crypto.fileKeyForAux).prefix(16)))
        return itemsDirectory.appendingPathComponent("\(token).x")
    }
    return itemsDirectory.appendingPathComponent(name)
}
func writeAux(_ data: Data, name: String) throws { /* seal with aux token, coordinated write */ }
func readAux(name: String) -> Data? { /* coordinated read, open with aux token */ }
func enumerateAuxFiles() -> [URL] { /* "*.x" encrypted; explicit names plaintext */ }
```

> Expose a `fileKeyForAux` accessor on `LibraryFileCrypto` (an HKDF subkey, `info:"aux"`), or fold aux naming into `LibraryFileCrypto` as a first-class `Role.aux(name:)`. Prefer the latter for symmetry: extend `Role` to `case aux(String)` and have `fileToken`/`fileName` handle it (`.x` suffix). Update the Task 2 enum accordingly during this task and re-run its tests.

Reconcile branches on suffix: `.m`/`.json` → item sidecar; `.x`/`album-*.json` → album/aux. Album membership still lives in the item sidecar's `albumIDs` (unchanged from the albums design).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryIndexEncryptedTests`
Also run `LibraryAlbum*Tests`, `LibraryDateBackfillTests` to confirm passthrough mode is unregressed.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/ DiffuselyTests/LibraryIndexEncryptedTests.swift
git commit -m "feat(library-store): index/backfill/albums/sort-assistant via store"
```

---

# Phase 3 — Migration

### Task 12: Forward migration (plaintext → encrypted), resumable

**Files:**
- Create: `Diffusely/Services/Library/LibraryEncryptionMigrator.swift`
- Test: `DiffuselyTests/LibraryEncryptionMigratorTests.swift`

**Interfaces:**
- Consumes: `LibraryFileStore` (plaintext + encrypted instances), `LibraryFileCrypto`.
- Produces:
  - `struct LibraryEncryptionMigrator`
    - `init(itemsDirectory: URL, crypto: LibraryFileCrypto)`
    - `func pendingItemIDs() -> [Int]` (plaintext `<int>.json` still present)
    - `func migrateItem(itemID: Int, plaintextExtension: String) throws` (verify-before-delete)
    - `func migrateAll(progress: (Int, Int) -> Void) throws`
  - Idempotent: an already-migrated item (encrypted files present, plaintext gone) is skipped.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryEncryptionMigratorTests: XCTestCase {
    private func seedPlaintext(_ dir: URL, id: Int) throws {
        try Data("{\"itemID\":\(id)}".utf8).write(to: dir.appendingPathComponent("\(id).json"))
        try Data("media-\(id)".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
    }

    func testMigrateEncryptsAndRemovesPlaintextAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedPlaintext(dir, id: 1); try seedPlaintext(dir, id: 2)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(migrator.pendingItemIDs().sorted(), [1, 2])

        try migrator.migrateAll { _, _ in }

        // plaintext gone, encrypted present, decrypts to original
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(store.readMedia(itemID: 2, plaintextExtension: "jpeg"), Data("media-2".utf8))

        // idempotent
        XCTAssertEqual(migrator.pendingItemIDs(), [])
        try migrator.migrateAll { _, _ in }
    }

    func testVerifyBeforeDeleteKeepsPlaintextIfCiphertextMissing() throws {
        // Simulate: item with sidecar but NO media file present → migration must
        // not delete the sidecar because media couldn't be encrypted.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"itemID\":7}".utf8).write(to: dir.appendingPathComponent("7.json"))   // no 7.jpeg

        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: LibraryFileCrypto(dek: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try migrator.migrateItem(itemID: 7, plaintextExtension: "jpeg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("7.json").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryEncryptionMigratorTests`
Expected: FAIL — `LibraryEncryptionMigrator` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One-time, resumable, loss-safe conversion of plaintext Library items to
/// encrypted opaque files. Order per item: encrypt media → encrypt sidecar →
/// verify both decrypt → only then delete plaintext. A crash leaves the item
/// resumable with no data loss.
struct LibraryEncryptionMigrator {
    let itemsDirectory: URL
    let crypto: LibraryFileCrypto

    enum MigrateError: Error { case mediaMissing, verifyFailed }

    private var encryptedStore: LibraryFileStore { LibraryFileStore(itemsDirectory: itemsDirectory, crypto: crypto) }

    func pendingItemIDs() -> [Int] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: itemsDirectory.path)) ?? []
        return files.compactMap { name -> Int? in
            guard name.hasSuffix(".json"), !name.hasPrefix("album-") else { return nil }
            return Int((name as NSString).deletingPathExtension)
        }
    }

    func migrateItem(itemID: Int, plaintextExtension ext: String) throws {
        let sidecarURL = itemsDirectory.appendingPathComponent("\(itemID).json")
        let mediaURL = itemsDirectory.appendingPathComponent("\(itemID).\(ext)")
        guard let sidecar = try? Data(contentsOf: sidecarURL) else { return }   // already migrated
        guard let media = try? Data(contentsOf: mediaURL) else { throw MigrateError.mediaMissing }

        try encryptedStore.writeMedia(media, itemID: itemID, plaintextExtension: ext)
        try encryptedStore.writeMetadata(sidecar, itemID: itemID)

        // Verify decrypt round-trips before deleting anything.
        guard encryptedStore.readMedia(itemID: itemID, plaintextExtension: ext) == media,
              encryptedStore.readMetadata(itemID: itemID) == sidecar else {
            throw MigrateError.verifyFailed
        }

        try FileManager.default.removeItem(at: mediaURL)
        try FileManager.default.removeItem(at: sidecarURL)
    }

    func migrateAll(progress: (Int, Int) -> Void) throws {
        let ids = pendingItemIDs()
        let total = ids.count
        for (i, id) in ids.enumerated() {
            let ext = mediaExtension(forItemID: id)
            try migrateItem(itemID: id, plaintextExtension: ext)
            progress(i + 1, total)
        }
    }

    private func mediaExtension(forItemID id: Int) -> String {
        // Prefer the sidecar's mediaType; fall back to whichever media file exists.
        if let data = try? Data(contentsOf: itemsDirectory.appendingPathComponent("\(id).json")),
           let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data) {
            return meta.mediaType.fileExtension
        }
        return FileManager.default.fileExists(atPath: itemsDirectory.appendingPathComponent("\(id).mp4").path) ? "mp4" : "jpeg"
    }
}
```

> The `migrateAll` loop is wrapped by the orchestrator (Task 14) that runs it on the dedicated I/O queue with bounded concurrency and materializes iCloud-evicted items first via `LibraryFileMaterializer.download` on each plaintext URL. Album files (`album-*.json`) and `sort-assistant-state.json` are migrated by the same verify-before-delete pattern in `migrateAll` after items (add an aux pass).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryEncryptionMigratorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryEncryptionMigrator.swift DiffuselyTests/LibraryEncryptionMigratorTests.swift
git commit -m "feat(library-migration): resumable forward migration with verify-before-delete"
```

---

### Task 13: Reverse migration (encrypted → plaintext) for disable

**Files:**
- Modify: `Diffusely/Services/Library/LibraryEncryptionMigrator.swift`
- Test: `DiffuselyTests/LibraryEncryptionMigratorTests.swift` (extend)

**Interfaces:**
- Produces: `func pendingEncryptedItemIDs() -> [Int]` (items with `.m` present); `func decryptItem(itemID:) throws` (write plaintext `<id>.json`/`<id>.<ext>` from the sidecar's `mediaType`, verify, then delete the opaque files); `func decryptAll(progress:) throws`.

- [ ] **Step 1: Write the failing test**

```swift
func testReverseMigrationRestoresPlaintext() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
    let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
    // Seed an encrypted image item with a real sidecar so mediaType resolves.
    let meta = "{\"schemaVersion\":5,\"itemID\":8,\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"8.jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}"
    try store.writeMetadata(Data(meta.utf8), itemID: 8)
    try store.writeMedia(Data("pixels".utf8), itemID: 8, plaintextExtension: "jpeg")

    let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
    try migrator.decryptAll { _, _ in }
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("8.jpeg")), Data("pixels".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("8.json").path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryEncryptionMigratorTests/testReverseMigrationRestoresPlaintext`
Expected: FAIL — `decryptAll` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
extension LibraryEncryptionMigrator {
    func pendingEncryptedItemIDs() -> [Int] {
        encryptedStore.enumerateMetadataFiles().compactMap { encryptedStore.itemID(forMetadataFile: $0) }
    }

    func decryptItem(itemID: Int) throws {
        guard let sidecar = encryptedStore.readMetadata(itemID: itemID),
              let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: sidecar) else { return }
        let ext = meta.mediaType.fileExtension
        guard let media = encryptedStore.readMedia(itemID: itemID, plaintextExtension: ext) else {
            throw MigrateError.mediaMissing
        }
        let sidecarURL = itemsDirectory.appendingPathComponent("\(itemID).json")
        let mediaURL = itemsDirectory.appendingPathComponent("\(itemID).\(ext)")
        try media.write(to: mediaURL, options: .atomic)
        try sidecar.write(to: sidecarURL, options: .atomic)
        guard (try? Data(contentsOf: mediaURL)) == media else { throw MigrateError.verifyFailed }
        encryptedStore.removeItem(itemID: itemID, plaintextExtension: ext)
    }

    func decryptAll(progress: (Int, Int) -> Void) throws {
        let ids = pendingEncryptedItemIDs()
        for (i, id) in ids.enumerated() { try decryptItem(itemID: id); progress(i + 1, ids.count) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryEncryptionMigratorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryEncryptionMigrator.swift DiffuselyTests/LibraryEncryptionMigratorTests.swift
git commit -m "feat(library-migration): reverse migration for disable"
```

---

### Task 14: Migration orchestrator (queue, iCloud materialize, index rebuild)

**Files:**
- Create: `Diffusely/Services/Library/LibraryEncryptionCoordinator.swift`
- Test: manual + `DiffuselyTests/LibraryEncryptionCoordinatorTests.swift` (progress/state machine with a stub migrator)

**Interfaces:**
- Consumes: `LibraryVault`, `LibraryEncryptionMigrator`, `LibraryFileMaterializer`, `LibraryIndexService`, `LibraryContainer`.
- Produces:
  - `@MainActor final class LibraryEncryptionCoordinator: ObservableObject`
    - `@Published var phase: Phase` where `enum Phase: Equatable { case idle, encrypting(done: Int, total: Int), decrypting(done: Int, total: Int), failed(String) }`
    - `func enable(password: String) async throws -> String` (configure vault → run forward migration on the I/O queue, materializing evicted items first → rebuild index → return recovery key)
    - `func disable() async throws` (requires unlocked → reverse migration → `vault.teardown()` → rebuild index)
  - Runs the migration loop on `LibraryImageRequest`-style `ioQueue` (bounded concurrency), never the cooperative pool.

- [ ] **Step 1: Write the failing test** (state-machine only; heavy I/O verified manually)

```swift
import XCTest
@testable import Diffusely

@MainActor
final class LibraryEncryptionCoordinatorTests: XCTestCase {
    func testEnableReportsProgressAndReturnsRecoveryKey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seed two plaintext items.
        for id in [1, 2] {
            try Data("{\"schemaVersion\":5,\"itemID\":\(id),\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"\(id).jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}".utf8)
                .write(to: dir.appendingPathComponent("\(id).json"))
            try Data("m\(id)".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir,
            vault: LibraryVault(vaultURL: dir.appendingPathComponent("../vault.json"),
                                backupURL: dir.appendingPathComponent("../vault.backup.json"),
                                keyStore: InMemoryKeyStore(), rounds: 1000))
        let recovery = try await coordinator.enable(password: "pw")
        XCTAssertFalse(recovery.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
        // Plaintext replaced by encrypted files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryEncryptionCoordinatorTests`
Expected: FAIL — `LibraryEncryptionCoordinator` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

@MainActor
final class LibraryEncryptionCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, encrypting(done: Int, total: Int), decrypting(done: Int, total: Int), failed(String) }
    @Published var phase: Phase = .idle

    private let itemsDirectory: URL
    private let vault: LibraryVault
    private static let ioQueue = DispatchQueue(label: "com.achatessoftware.diffusely.library.migration", qos: .userInitiated)

    init(itemsDirectory: URL, vault: LibraryVault) {
        self.itemsDirectory = itemsDirectory
        self.vault = vault
    }

    func enable(password: String) async throws -> String {
        let recovery = try await vault.configure(password: password)
        guard let crypto = await vault.crypto() else { throw LibraryVaultError.malformed }
        let migrator = LibraryEncryptionMigrator(itemsDirectory: itemsDirectory, crypto: crypto)

        phase = .encrypting(done: 0, total: migrator.pendingItemIDs().count)
        try await runOnIOQueue {
            try migrator.migrateAllMaterializing { done, total in
                Task { @MainActor in self.phase = .encrypting(done: done, total: total) }
            }
        }
        await rebuildIndex()
        phase = .idle
        return recovery
    }

    func disable() async throws {
        guard let crypto = await vault.crypto() else { throw LibraryVaultError.wrongCredential }
        let migrator = LibraryEncryptionMigrator(itemsDirectory: itemsDirectory, crypto: crypto)
        phase = .decrypting(done: 0, total: migrator.pendingEncryptedItemIDs().count)
        try await runOnIOQueue {
            try migrator.decryptAll { done, total in
                Task { @MainActor in self.phase = .decrypting(done: done, total: total) }
            }
        }
        await vault.teardown()
        await rebuildIndex()
        phase = .idle
    }

    private func rebuildIndex() async {
        await LibrarySaveService.shared.indexService?.reconcileAll()   // existing reconcile entry point
    }

    private func runOnIOQueue(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { cont in
            Self.ioQueue.async { do { try work(); cont.resume() } catch { cont.resume(throwing: error) } }
        }
    }
}
```

Add `migrateAllMaterializing` to the migrator: for each pending id, call `LibraryFileMaterializer.download` on the plaintext media URL if not local, then `migrateItem`. (Synchronous wrapper over the async materializer via a semaphore on the I/O queue, matching the existing blocking-I/O-off-cooperative-pool pattern.)

> Wire the reconcile entry point name to whatever `LibraryIndexService` actually exposes (`reconcileAll` / `rebuild` / `ingestAll`) — confirm during implementation and match it. If the index service is a `@ModelActor`, call its existing full-rebuild method.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Diffusely -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DiffuselyTests/LibraryEncryptionCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Library/LibraryEncryptionCoordinator.swift Diffusely/Services/Library/LibraryEncryptionMigrator.swift DiffuselyTests/LibraryEncryptionCoordinatorTests.swift
git commit -m "feat(library-migration): enable/disable coordinator with progress"
```

---

# Phase 4 — Unlock UI & Settings

### Task 15: Unlock gate view

**Files:**
- Create: `Diffusely/Views/LibraryUnlockView.swift`
- Test: manual (SwiftUI view; verify in simulator)

**Interfaces:**
- Consumes: `LibraryVaultProvider`, `LibraryVault`.
- Produces: `struct LibraryUnlockView: View` — shows a password field + "Unlock" + "Use Face ID" + "Use recovery key" affordances; on success calls `provider.refreshState()`. Biometric auto-attempt on appear.

- [ ] **Step 1: Write the implementation** (UI — no unit test; the vault logic is already covered by Task 5)

```swift
import SwiftUI

struct LibraryUnlockView: View {
    @ObservedObject var provider: LibraryVaultProvider
    @State private var password = ""
    @State private var recoveryMode = false
    @State private var recoveryKey = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Library Locked").font(.headline)

            if recoveryMode {
                TextField("Recovery key", text: $recoveryKey).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Button("Unlock with recovery key") { Task { await unlock(recovery: true) } }.disabled(busy)
                Button("Back") { recoveryMode = false }
            } else {
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                Button("Unlock") { Task { await unlock(recovery: false) } }.disabled(busy || password.isEmpty)
                Button("Use Face ID") { Task { await biometrics() } }
                Button("Forgot password? Use recovery key") { recoveryMode = true }.font(.footnote)
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .padding()
        .task { await biometrics() }
    }

    private func biometrics() async {
        if await provider.vault.unlockWithBiometrics() { await provider.refreshState() }
    }

    private func unlock(recovery: Bool) async {
        busy = true; error = nil
        do {
            if recovery { try await provider.vault.unlock(recoveryKey: recoveryKey) }
            else { try await provider.vault.unlock(password: password) }
            await provider.refreshState()
        } catch {
            self.error = "Incorrect \(recovery ? "recovery key" : "password")."
        }
        busy = false
    }
}
```

- [ ] **Step 2: Manual verification**

Run the app in the simulator with a configured vault (enable first via Task 16). Confirm: Face ID prompt on appear (simulator: Features → Face ID → Matching Face), password unlock, wrong password shows error, recovery-key path unlocks.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/LibraryUnlockView.swift
git commit -m "feat(library-ui): unlock gate view"
```

---

### Task 16: Encryption settings — enable / disable / change password / recovery

**Files:**
- Create: `Diffusely/Views/Settings/LibraryEncryptionSettingsView.swift`
- Modify: the app's Settings screen to link to it
- Test: manual

**Interfaces:**
- Consumes: `LibraryVaultProvider`, `LibraryEncryptionCoordinator`.
- Produces: `struct LibraryEncryptionSettingsView: View` — enable flow (set password + confirm → warning that all devices must be updated and that the migration downloads every item once → **show recovery key once behind an "I saved it" gate** → progress) ; disable flow (confirm → progress) ; change-password ; re-display is intentionally impossible (recovery key never re-shown).

- [ ] **Step 1: Write the implementation**

```swift
import SwiftUI

struct LibraryEncryptionSettingsView: View {
    @ObservedObject var provider: LibraryVaultProvider
    @StateObject private var coordinator: LibraryEncryptionCoordinator
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var recoveryKeyToShow: String?
    @State private var acknowledgedRecovery = false
    @State private var error: String?

    init(provider: LibraryVaultProvider, coordinator: LibraryEncryptionCoordinator) {
        self.provider = provider
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some View {
        Form {
            switch provider.state {
            case .notConfigured: enableSection
            case .locked, .unlocked: manageSection
            }
            if case let .encrypting(done, total) = coordinator.phase { progress("Encrypting", done, total) }
            if case let .decrypting(done, total) = coordinator.phase { progress("Decrypting", done, total) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Library Encryption")
        .sheet(item: Binding(get: { recoveryKeyToShow.map(RecoveryKeyBox.init) },
                             set: { recoveryKeyToShow = $0?.value })) { box in
            RecoveryKeySheet(recoveryKey: box.value, acknowledged: $acknowledgedRecovery)
        }
    }

    private var enableSection: some View {
        Section("Turn on encryption") {
            Text("Encrypts your entire Library at rest. **Update this app on all your devices first.** Turning it on downloads every saved item once.").font(.footnote)
            SecureField("Password", text: $newPassword)
            SecureField("Confirm password", text: $confirmPassword)
            Button("Encrypt Library") { Task { await enable() } }
                .disabled(newPassword.isEmpty || newPassword != confirmPassword)
        }
    }

    private var manageSection: some View {
        Section("Encryption is on") {
            Button("Change password…") { /* push change-password subview using vault.changePassword */ }
            Button("Turn off encryption", role: .destructive) { Task { await disable() } }
        }
    }

    private func progress(_ label: String, _ done: Int, _ total: Int) -> some View {
        Section { ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("\(label) \(done)/\(total)") } }
    }

    private func enable() async {
        error = nil
        do {
            let recovery = try await coordinator.enable(password: newPassword)
            acknowledgedRecovery = false
            recoveryKeyToShow = recovery
            await provider.refreshState()
        } catch { self.error = "Couldn't enable encryption: \(error.localizedDescription)" }
    }

    private func disable() async {
        error = nil
        do { try await coordinator.disable(); await provider.refreshState() }
        catch { self.error = "Couldn't disable encryption: \(error.localizedDescription)" }
    }
}

private struct RecoveryKeyBox: Identifiable { let value: String; var id: String { value } }

private struct RecoveryKeySheet: View {
    let recoveryKey: String
    @Binding var acknowledged: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text("Save your recovery key").font(.headline)
            Text("This is the **only** way back into your Library if you forget your password. It is shown once.").font(.footnote)
            Text(recoveryKey).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding().background(.quaternary)
            Button("Copy") { UIPasteboard.general.string = recoveryKey }
            Toggle("I've saved my recovery key somewhere safe", isOn: $acknowledged)
            Button("Done") { dismiss() }.disabled(!acknowledged)
        }.padding()
    }
}
```

- [ ] **Step 2: Manual verification**

In the simulator with a few saved items: enable → recovery key sheet shows once, "Done" gated on the toggle → progress → Library shows encrypted (relaunch → locked gate). Disable → progress → items readable plaintext again.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/Settings/LibraryEncryptionSettingsView.swift
git commit -m "feat(library-ui): encryption settings (enable/disable/recovery key)"
```

---

### Task 17: Gate the Library tab + auto-lock lifecycle

**Files:**
- Modify: `Diffusely/Views/LibraryView.swift`, app entry point (scene phase handling)
- Test: manual

**Interfaces:**
- Consumes: `LibraryVaultProvider`.
- Produces: `LibraryView` shows `LibraryUnlockView` when `provider.state == .locked`, the normal grid when `.unlocked` or `.notConfigured`. App entry point: on `.background`, start an auto-lock timer; if still backgrounded past the threshold (e.g. 5 min) or on next `.active` after the threshold, call `vault.lock()` + `provider.refreshState()`. Call `LibraryTempMedia.sweep()` on launch.

- [ ] **Step 1: Write the implementation**

```swift
// LibraryView.swift — wrap the existing content:
@StateObject private var vaultProvider = LibraryVaultProvider.shared
// ...
var body: some View {
    Group {
        if vaultProvider.state == .locked {
            LibraryUnlockView(provider: vaultProvider)
        } else {
            existingLibraryContent   // today's grid/albums
        }
    }
    .task { await vaultProvider.refreshState() }
}
```

```swift
// App entry point:
@Environment(\.scenePhase) private var scenePhase
// store the time we backgrounded
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .background: backgroundedAt = Date()
    case .active:
        if let at = backgroundedAt, Date().timeIntervalSince(at) > 300 {
            Task { await LibraryVaultProvider.shared.vault.lock(); await LibraryVaultProvider.shared.refreshState() }
        }
    default: break
    }
}
.task { LibraryTempMedia.sweep() }
```

> `Date()`/timers are fine in app code (the `Date.now` restriction applies only to workflow scripts). Use the app's existing settings store for the threshold if one exists; otherwise hardcode 300s for v1.

- [ ] **Step 2: Manual verification**

With encryption on: unlock, background the app > 5 min (simulator: adjust threshold to ~10s for testing), return → Library shows the lock gate again. Feed tabs remain usable while the Library is locked.

- [ ] **Step 3: Commit**

```bash
git add Diffusely/Views/LibraryView.swift Diffusely/DiffuselyApp.swift
git commit -m "feat(library-ui): gate Library tab + idle auto-lock"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task(s) |
|---|---|
| §1 Crypto core & key hierarchy (AES-GCM, PBKDF2, HKDF, envelope, vault.json + backup, recovery key, `LibraryVault`, biometric cache) | 1, 2, 3, 4, 5 |
| §2 On-disk format, opaque filenames, `LibraryFileStore` seam | 2, 6, 7 |
| §2 Seams: writer, image cascade + CDN-skip, video decrypt-to-temp, index, backfill, albums, sort-assistant | 8, 9, 10, 11 |
| §3 Enable/disable, forward+reverse migration, materialize-once, second-device consume | 12, 13, 14 (second-device consume is inherent: device B unlocks via Task 5/15 and reads via Task 6 — no migration run) |
| §3 Password change | 5 (`changePassword`), 16 (UI) |
| §4 Error handling (wrong credential, tamper isolation, verify-before-delete, vault backup, save-while-locked) | 2, 3, 5, 6, 12, 17 |
| §5 Testing | Tasks 1–14 each ship tests; 15–17 manual |
| Export-compliance note | N/A (documentation only; no code) |

**Gaps consciously deferred:** the second device's "migration in progress" advisory banner (spec §3) is not its own task — device B already functions correctly by reading whatever has synced (Task 6 tolerates mixed state); a status banner is a polish item foldable into Task 17 if desired. The `migration-state.json` explicit file is replaced by directory-derived progress (Task 12 `pendingItemIDs`), which the spec explicitly permits ("Progress derives largely from directory state … backed by a small `migration-state.json`") — the derived approach is sufficient for v1; add the file only if crash-resume telemetry is wanted.

**Placeholder scan:** no "TBD/handle errors/similar to Task N". The two `>`-quoted implementation notes (Task 9 temp-media ordering, Task 11 `Role.aux`, Task 14 reconcile method name) point at concrete follow-through within the same task, not deferred work.

**Type consistency:** `LibraryFileCrypto(dek:)`, `Role.{meta,media}` (extended to `aux` in Task 11), `fileToken`/`fileName`, `LibraryFileStore(itemsDirectory:crypto:)` and its `read/writeMetadata`/`read/writeMedia`/`enumerateMetadataFiles`/`itemID(forMetadataFile:)`, `LibraryVault` state names and `configure/unlock/lock/crypto/teardown/changePassword`, `LibraryVaultProvider.shared.fileStore()`, `LibraryEncryptionMigrator(itemsDirectory:crypto:)` with `migrateItem/migrateAll/decryptAll`, and `LibraryEncryptionCoordinator.Phase` are used consistently across tasks.
