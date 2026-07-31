import XCTest
import CryptoKit
@testable import Diffusely

final class LibraryEncryptionMigratorTests: XCTestCase {
    private func seedPlaintext(_ dir: URL, id: Int) throws {
        try Data("{\"itemID\":\(id)}".utf8).write(to: dir.appendingPathComponent("\(id).json"))
        try Data("media-\(id)".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
    }

    /// Like `seedPlaintext`, but writes a fully decodable `LibraryItemMetadata`
    /// sidecar rather than a bare `{ itemID }` stub. Forward-only tests don't
    /// need this (`migrateItem` never decodes the sidecar — it just moves
    /// bytes), but `decryptItem` DOES decode it to learn `mediaType`, so any
    /// test that migrates an item forward and then reverses it needs a real,
    /// fully-decodable sidecar seeded up front.
    private func seedFullPlaintext(_ dir: URL, id: Int) throws {
        let meta = "{\"schemaVersion\":5,\"itemID\":\(id),\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"\(id).jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}"
        try Data(meta.utf8).write(to: dir.appendingPathComponent("\(id).json"))
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

    // MARK: Crash-orphan self-heal — a prior run killed between the two
    // final plaintext deletes (media already gone, sidecar left behind)
    // leaves the item already fully/verifiably encrypted. Re-running must
    // recognize that and clean up quietly instead of throwing forever.

    func testCrashOrphanedSidecarSelfHealsWithoutThrowing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedPlaintext(dir, id: 1)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.migrateItem(itemID: 1, plaintextExtension: "jpeg")   // normal, successful migration

        // Simulate the crash: a stray plaintext sidecar reappears (byte-for-
        // byte identical to what was migrated) with no matching plaintext
        // media — exactly what's left behind if the process died after
        // deleting "1.jpeg" but before deleting "1.json".
        try Data("{\"itemID\":1}".utf8).write(to: dir.appendingPathComponent("1.json"))

        XCTAssertNoThrow(try migrator.migrateItem(itemID: 1, plaintextExtension: "jpeg"))

        // Orphan cleaned up; encrypted files untouched and still correct.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.jpeg").path))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(store.readMedia(itemID: 1, plaintextExtension: "jpeg"), Data("media-1".utf8))
        XCTAssertEqual(store.readMetadata(itemID: 1), Data("{\"itemID\":1}".utf8))

        // And migrateAll (which would otherwise wedge on the repeated
        // .mediaMissing throw) now sees nothing pending.
        XCTAssertEqual(migrator.pendingItemIDs(), [])
    }

    // MARK: verifyFailed — the just-written ciphertext must be proven to
    // decrypt back to the original bytes before any plaintext is deleted.

    func testVerifyFailedThrowsAndRetainsPlaintext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedPlaintext(dir, id: 9)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        // Deliberately mismatched: the verify-before-delete read goes
        // through a store keyed by a DIFFERENT dek than the one that wrote
        // the ciphertext, so the decrypt round-trip is guaranteed to fail.
        let migrator = LibraryEncryptionMigrator(
            itemsDirectory: dir,
            crypto: crypto,
            verifyCryptoOverride: LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        )

        XCTAssertThrowsError(try migrator.migrateItem(itemID: 9, plaintextExtension: "jpeg")) { error in
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .verifyFailed)
        }

        // Plaintext retained — nothing was deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("9.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("9.jpeg").path))
    }

    // MARK: Aux pass — album files and sort-assistant state migrate the same
    // verify-before-delete way, after the item pass, inside migrateAll.

    func testMigrateAllMigratesAuxAlbumAndSortAssistantStateFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let albumFileName = "album-\(UUID().uuidString).json"
        let albumPayload = Data("{\"name\":\"Favorites\"}".utf8)
        try albumPayload.write(to: dir.appendingPathComponent(albumFileName))

        let sortAssistantFileName = "sort-assistant-state.json"
        let sortAssistantPayload = Data("{\"schemaVersion\":1,\"rejected\":{},\"rejectedNewAlbum\":[]}".utf8)
        try sortAssistantPayload.write(to: dir.appendingPathComponent(sortAssistantFileName))

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)

        try migrator.migrateAll { _, _ in }

        // No literal plaintext names left in the directory.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(albumFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(sortAssistantFileName).path))
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.allSatisfy { $0.lastPathComponent.hasSuffix(".x") })
        XCTAssertEqual(remaining.count, 2)

        // Decrypt back to the exact originals.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(store.readAux(name: albumFileName), albumPayload)
        XCTAssertEqual(store.readAux(name: sortAssistantFileName), sortAssistantPayload)
    }

    // MARK: Reverse migration (encrypted → plaintext, for disabling encryption)

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

        // Encrypted files gone.
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [])
        XCTAssertTrue(store.enumerateMetadataFiles().isEmpty)
    }

    func testRoundTripForwardThenReverseRestoresByteIdenticalPlaintext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 3)
        let originalSidecar = try Data(contentsOf: dir.appendingPathComponent("3.json"))
        let originalMedia = try Data(contentsOf: dir.appendingPathComponent("3.jpeg"))

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)

        try migrator.migrateItem(itemID: 3, plaintextExtension: "jpeg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("3.json").path))

        try migrator.decryptItem(itemID: 3)

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("3.json")), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("3.jpeg")), originalMedia)
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [])
    }

    func testReverseAuxRestoresAlbumAndSortAssistantStateLiteralNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)

        let albumID = UUID()
        let albumFileName = LibraryAlbumStore.fileName(for: albumID)
        let albumPayload = try LibraryAlbumFile.encoder().encode(
            LibraryAlbumFile(id: albumID, name: "Favorites", createdAt: Date(timeIntervalSince1970: 0))
        )
        try store.writeAux(albumPayload, name: albumFileName)

        let sortAssistantFileName = SortAssistantStateStore.fileName
        let sortAssistantPayload = try JSONEncoder().encode(
            SortAssistantState(schemaVersion: 1, rejected: [:], rejectedNewAlbum: [])
        )
        try store.writeAux(sortAssistantPayload, name: sortAssistantFileName)

        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.decryptAll { _, _ in }

        // Literal plaintext names present, decrypt-correct.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(albumFileName)), albumPayload)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(sortAssistantFileName)), sortAssistantPayload)

        // No opaque aux files left.
        XCTAssertTrue(store.enumerateAuxFiles().isEmpty)
    }

    func testReverseVerifyBeforeDeleteKeepsCiphertextOnMismatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 11)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let forwardMigrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try forwardMigrator.migrateItem(itemID: 11, plaintextExtension: "jpeg")

        // Deliberately mismatched: the reverse verify-before-delete read goes
        // through a store keyed by a DIFFERENT dek than the one that
        // encrypted the ciphertext, so the independent re-decrypt is
        // guaranteed to disagree.
        let reverseMigrator = LibraryEncryptionMigrator(
            itemsDirectory: dir,
            crypto: crypto,
            verifyCryptoOverride: LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        )

        XCTAssertThrowsError(try reverseMigrator.decryptItem(itemID: 11)) { error in
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .verifyFailed)
        }

        // Ciphertext retained — never deleted since verify failed.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        XCTAssertNotNil(store.readMetadata(itemID: 11))
        XCTAssertNotNil(store.readMedia(itemID: 11, plaintextExtension: "jpeg"))
    }

    // MARK: Crash-orphan self-heal (reverse) — a prior run wrote+verified the
    // plaintext but crashed before deleting the ciphertext. Re-running must
    // recognize that and clean up quietly instead of throwing or re-writing.

    func testReverseCrashOrphanedCiphertextSelfHealsWithoutThrowing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 5)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.migrateItem(itemID: 5, plaintextExtension: "jpeg")   // now fully encrypted

        // Simulate the crash: plaintext reappears (byte-for-byte identical to
        // what decrypting the ciphertext would produce) while the ciphertext
        // is STILL present — exactly what's left behind if the process died
        // after decryptItem wrote+verified the plaintext but before it called
        // removeItem on the ciphertext.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let sidecar = store.readMetadata(itemID: 5)!
        let media = store.readMedia(itemID: 5, plaintextExtension: "jpeg")!
        try sidecar.write(to: dir.appendingPathComponent("5.json"), options: .atomic)
        try media.write(to: dir.appendingPathComponent("5.jpeg"), options: .atomic)

        XCTAssertNoThrow(try migrator.decryptItem(itemID: 5))

        // Ciphertext cleaned up; plaintext intact and correct.
        XCTAssertNil(store.readMetadata(itemID: 5))
        XCTAssertNil(store.readMedia(itemID: 5, plaintextExtension: "jpeg"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("5.json")), sidecar)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("5.jpeg")), media)

        // And decryptAll (which would otherwise wedge if it re-threw) now
        // sees nothing pending.
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [])
    }

    // MARK: Crash-orphan self-heal (reverse), narrower window — `removeItem`
    // deletes ciphertext media BEFORE ciphertext metadata, so a crash inside
    // that single call can also leave metadata-present/media-absent, with
    // the plaintext already fully written+verified. Distinct code path from
    // the "both ciphertext files still present" case above.

    func testReverseSelfHealsWhenOnlyCiphertextMediaOrphanedAfterRemoveItemCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 44)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.migrateItem(itemID: 44, plaintextExtension: "jpeg")   // now fully encrypted

        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let sidecar = store.readMetadata(itemID: 44)!
        let media = store.readMedia(itemID: 44, plaintextExtension: "jpeg")!

        // Simulate the narrower crash window: `removeItem` (media first, then
        // metadata) deleted ciphertext media and crashed before deleting
        // ciphertext metadata — but only after THIS same call's plaintext
        // write+verify had already fully succeeded.
        try FileManager.default.removeItem(at: store.mediaURL(itemID: 44, plaintextExtension: "jpeg"))
        try sidecar.write(to: dir.appendingPathComponent("44.json"), options: .atomic)
        try media.write(to: dir.appendingPathComponent("44.jpeg"), options: .atomic)

        XCTAssertNoThrow(try migrator.decryptItem(itemID: 44))

        // Leftover ciphertext metadata cleaned up; plaintext intact and correct.
        XCTAssertNil(store.readMetadata(itemID: 44))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("44.json")), sidecar)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("44.jpeg")), media)
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [])
    }

    func testReverseMediaMissingThrowsWhenNoCiphertextMediaAndNoPlaintextToProveSelfHeal() throws {
        // Sanity check that `isMetadataOnlyCrashOrphan` can't false-positive:
        // ciphertext metadata present, ciphertext media never written, and NO
        // plaintext anywhere to prove a prior successful decrypt — this must
        // be a genuine failure, not a self-heal.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let meta = "{\"schemaVersion\":5,\"itemID\":33,\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"33.jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}"
        try store.writeMetadata(Data(meta.utf8), itemID: 33)   // no media ever written

        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        XCTAssertThrowsError(try migrator.decryptItem(itemID: 33)) { error in
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .mediaMissing)
        }
        XCTAssertNotNil(store.readMetadata(itemID: 33))   // ciphertext retained
    }

    // MARK: Self-heal must never fire on a merely-present-but-wrong plaintext
    // — only a byte-exact match short-circuits the write.

    func testDecryptItemOverwritesStalePlaintextRatherThanSelfHealing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 21)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.migrateItem(itemID: 21, plaintextExtension: "jpeg")   // now fully encrypted, plaintext gone

        // Stale/wrong plaintext reappears — NOT byte-identical to what the
        // ciphertext decrypts to (unlike the genuine crash-orphan case). Must
        // be overwritten with the correct decrypted bytes, not mistaken for
        // an already-correct self-heal case.
        try Data("{\"itemID\":21,\"stale\":true}".utf8).write(to: dir.appendingPathComponent("21.json"))
        try Data("stale-wrong-media".utf8).write(to: dir.appendingPathComponent("21.jpeg"))

        try migrator.decryptItem(itemID: 21)

        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("21.jpeg")), Data("media-21".utf8))
        let restoredSidecar = try String(contentsOf: dir.appendingPathComponent("21.json"), encoding: .utf8)
        XCTAssertTrue(restoredSidecar.contains("\"schemaVersion\":5"))
        XCTAssertFalse(restoredSidecar.contains("stale"))
        XCTAssertNil(store.readMetadata(itemID: 21))
        XCTAssertNil(store.readMedia(itemID: 21, plaintextExtension: "jpeg"))
    }

    // MARK: decryptAll's hard completeness guarantee — a non-throwing return
    // must mean zero ciphertext remains, since a caller (the disable-
    // encryption coordinator) will treat it as license to discard the DEK.

    func testDecryptAllThrowsIncompleteWhenItemFailsFullDecodeButPassesStubDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)

        // Decodes fine as the tiny `{ itemID }` stub `pendingEncryptedItemIDs()`
        // uses, but is missing every other required field for the FULL
        // `LibraryItemMetadata` decode `decryptItem` needs to learn the
        // extension — simulating a corrupt/foreign-schema sidecar that would
        // otherwise silently strand this item's ciphertext forever.
        let stubOnlyMeta = "{\"itemID\":42}"
        try store.writeMetadata(Data(stubOnlyMeta.utf8), itemID: 42)
        try store.writeMedia(Data("pixels".utf8), itemID: 42, plaintextExtension: "jpeg")

        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [42])

        XCTAssertThrowsError(try migrator.decryptAll { _, _ in }) { error in
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .incomplete)
        }

        // Ciphertext retained — the item was never actually converted, so a
        // caller must NOT treat this as safe to discard the DEK.
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [42])
    }

    /// `pendingEncryptedItemIDs()` is `enumerateMetadataFiles().compactMap {
    /// itemID(forMetadataFile:) }` — a `.m` sidecar whose GCM-open fails is
    /// silently DROPPED by `compactMap`, not surfaced. Before this fix, a
    /// corrupted-on-disk sidecar (with its `.b` media still intact) was
    /// therefore invisible to `decryptAll`'s post-loop
    /// `pendingEncryptedItemIDs().isEmpty` recheck: the guard would pass,
    /// `decryptAll` would return normally, and the disable-encryption
    /// coordinator would trust that clean return and tear down the vault —
    /// discarding the DEK while this item's ciphertext was still sitting on
    /// disk, permanently unrecoverable. The guard now ALSO re-checks the raw
    /// `encryptedStore.enumerateMetadataFiles()` file listing (no decode, so
    /// an undecodable sidecar still counts as "remaining"), which this test
    /// exercises directly.
    func testDecryptAllThrowsIncompleteWhenSidecarIsCorruptedOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 3)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.migrateItem(itemID: 3, plaintextExtension: "jpeg")   // now fully encrypted

        // Corrupt the ciphertext sidecar on disk (garbage bytes — GCM-open
        // will fail) while leaving the ciphertext media untouched.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let sidecarURL = store.metadataURL(itemID: 3)
        try Data("not a valid sealed box".utf8).write(to: sidecarURL, options: .atomic)

        // The corrupted sidecar is invisible to the decoded-ids view...
        XCTAssertEqual(migrator.pendingEncryptedItemIDs(), [])
        // ...but its file is still there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        XCTAssertThrowsError(try migrator.decryptAll { _, _ in }) { error in
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .incomplete)
        }
        // The corrupted sidecar file must still be there — nothing silently
        // deleted or otherwise "resolved" it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    /// Same regression, exercised through `decryptAllMaterializing` (the
    /// entry point `LibraryEncryptionCoordinator.disable` actually calls).
    func testDecryptAllMaterializingThrowsIncompleteWhenSidecarIsCorruptedOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedFullPlaintext(dir, id: 4)

        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        try migrator.migrateItem(itemID: 4, plaintextExtension: "jpeg")   // now fully encrypted

        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let sidecarURL = store.metadataURL(itemID: 4)
        try Data("not a valid sealed box".utf8).write(to: sidecarURL, options: .atomic)

        XCTAssertThrowsError(try migrator.decryptAllMaterializing { _, _ in }) { error in
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .incomplete)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }
}
