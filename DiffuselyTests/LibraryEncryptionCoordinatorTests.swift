import XCTest
import Combine
@testable import Diffusely

@MainActor
final class LibraryEncryptionCoordinatorTests: XCTestCase {
    /// Full, decodable sidecar (not just the `{ itemID }` stub) so a reverse
    /// migration (triggered indirectly by `disable()`) can decode `mediaType`
    /// via `decryptItem`.
    private func seedPlaintext(_ dir: URL, id: Int) throws {
        try Data("{\"schemaVersion\":5,\"itemID\":\(id),\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"\(id).jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}".utf8)
            .write(to: dir.appendingPathComponent("\(id).json"))
        try Data("m\(id)".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a vault rooted alongside (not "../" out of) `dir`. The task
    /// brief's own verbatim reference test used `dir.appendingPathComponent
    /// ("../vault.json")`, which — since `dir` is directly under the shared
    /// system `temporaryDirectory`, not nested one level like production's
    /// `Documents/Items` — collapses to a single vault.json path shared by
    /// EVERY test in this file (and every other test run) rather than one
    /// scoped to this test's own temp directory. That cross-test collision
    /// is real, not hypothetical: the disable-safety test below deliberately
    /// leaves its vault configured (never tears down), so a suite run that
    /// hit that test before this one would leave a stray vault.json behind,
    /// and the next test's `vault.configure()` would throw `.malformed`
    /// against an "already configured" vault it never created. Scoping the
    /// vault files to `dir` itself (safe: `vault.json`/`vault.backup.json`
    /// don't match `pendingItemIDs()`'s `<Int>.json` filter or the `album-`
    /// aux prefix) keeps every test's vault fully isolated.
    private func makeVault(_ dir: URL) -> LibraryVault {
        LibraryVault(
            vaultURL: dir.appendingPathComponent("vault.json"),
            backupURL: dir.appendingPathComponent("vault.backup.json"),
            keyStore: InMemoryKeyStore(), rounds: 1000
        )
    }

    func testEnableReportsProgressAndReturnsRecoveryKey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seed two plaintext items.
        for id in [1, 2] {
            try Data("{\"schemaVersion\":5,\"itemID\":\(id),\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"\(id).jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}".utf8)
                .write(to: dir.appendingPathComponent("\(id).json"))
            try Data("m\(id)".utf8).write(to: dir.appendingPathComponent("\(id).jpeg"))
        }
        // NOTE: vault paths deliberately scoped to `dir` (not the brief's
        // literal "../vault.json") — see `makeVault`'s doc comment.
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir,
            vault: makeVault(dir),
            rebuildIndex: {})

        // Capture every published `phase` transition so we can confirm the
        // progress path (not just the terminal `.idle`) actually fires —
        // previously unverified.
        var observedPhases: [LibraryEncryptionCoordinator.Phase] = []
        var cancellables = Set<AnyCancellable>()
        coordinator.$phase
            .sink { observedPhases.append($0) }
            .store(in: &cancellables)

        let recovery = try await coordinator.enable(password: "pw")
        XCTAssertFalse(recovery.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
        // Plaintext replaced by encrypted files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))

        // At least one intermediate `.encrypting(done:total:)` update was
        // actually published during the run.
        XCTAssertTrue(observedPhases.contains {
            if case .encrypting = $0 { return true }
            return false
        }, "expected at least one .encrypting phase update, got \(observedPhases)")
    }

    func testDisableAfterEnableRestoresPlaintextAndTearsDownVault() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)
        try seedPlaintext(dir, id: 2)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})

        _ = try await coordinator.enable(password: "pw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))

        try await coordinator.disable()

        XCTAssertEqual(coordinator.phase, .idle)
        // Plaintext restored, byte-identical media.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.jpeg")), Data("m1".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("2.jpeg")), Data("m2".utf8))
        // No opaque encrypted files left behind.
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.allSatisfy { $0.lastPathComponent.hasSuffix(".json") || $0.lastPathComponent.hasSuffix(".jpeg") })

        // Vault fully torn down.
        let state = await vault.state()
        XCTAssertEqual(state, .notConfigured)
    }

    /// If `decryptAll` would throw `.incomplete` (a stray encrypted file that
    /// can't be fully decoded survives the pass), `disable()` must throw AND
    /// must NOT tear down the vault — the DEK is still needed to finish
    /// decrypting the leftover item on a retry. Tearing down here would
    /// permanently strand that item's ciphertext.
    func testDisableDoesNotTearDownVaultWhenDecryptAllWouldBeIncomplete() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")

        guard let crypto = await vault.crypto() else {
            XCTFail("vault should be unlocked with a cached DEK after enable()")
            return
        }

        // Seed a stray encrypted item whose sidecar decodes fine as the tiny
        // `{ itemID }` stub `pendingEncryptedItemIDs()` uses, but fails the
        // full `LibraryItemMetadata` decode `decryptItem` needs to learn the
        // extension — this is exactly what makes `decryptAll` throw
        // `.incomplete` rather than silently drop the item.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(Data("{\"itemID\":999}".utf8), itemID: 999)
        try store.writeMedia(Data("pixels".utf8), itemID: 999, plaintextExtension: "jpeg")

        do {
            try await coordinator.disable()
            XCTFail("expected disable() to throw when decryptAll is incomplete")
        } catch {
            // Expected.
        }

        if case .failed = coordinator.phase {
            // Expected.
        } else {
            XCTFail("expected phase to be .failed, got \(coordinator.phase)")
        }

        // The DEK must survive: vault still unlocked with crypto available,
        // NOT torn down.
        let stateAfter = await vault.state()
        XCTAssertEqual(stateAfter, .unlocked)
        let cryptoAfter = await vault.crypto()
        XCTAssertNotNil(cryptoAfter)

        // The stray item's ciphertext is still there too — nothing was lost.
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        XCTAssertTrue(migrator.pendingEncryptedItemIDs().contains(999))
    }

    /// If migration fails partway through `enable()` (after `vault.configure`
    /// has already succeeded), `phase` must become `.failed` and the error
    /// must rethrow — `enable()` must not silently swallow a migration
    /// failure or leave `phase` looking like nothing happened.
    func testEnableSetsFailedPhaseAndRethrowsOnMigrationFailure() async throws {
        let dir = try makeTempDir()
        // Sidecar present, but NO matching plaintext media and no
        // pre-existing ciphertext — `migrateItem` throws `.mediaMissing` (a
        // genuine failure, not the crash-orphan self-heal), forcing the
        // forward migration pass to fail.
        try Data("{\"itemID\":7}".utf8).write(to: dir.appendingPathComponent("7.json"))

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})

        do {
            _ = try await coordinator.enable(password: "pw")
            XCTFail("expected enable() to throw when migration fails")
        } catch {
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .mediaMissing)
        }

        if case .failed = coordinator.phase {
            // Expected.
        } else {
            XCTFail("expected phase to be .failed, got \(coordinator.phase)")
        }
    }

    /// `disable()` routes through `decryptAllMaterializing`, which
    /// materializes each item's ciphertext media — and, defensively, its
    /// ciphertext sidecar, plus any ciphertext aux files — from iCloud
    /// before decrypting (see that function's doc comment for why
    /// `disable()` would otherwise get permanently stuck against a large
    /// library whose encrypted media had been evicted). A real eviction
    /// can't be faked over a plain local temp directory (there's no way to
    /// mark a file `.isUbiquitousItemKey` without it actually living in an
    /// iCloud container), so this exercises the materialize-then-decrypt
    /// round trip over already-local files — for both an item AND an aux
    /// file (an album file), which
    /// `testDisableAfterEnableRestoresPlaintextAndTearsDownVault` doesn't
    /// cover — confirming `materializeIfNeeded`'s fast no-op path (already
    /// local, so `isReady` short-circuits before any real download attempt)
    /// doesn't change or break the decrypt outcome, and that `disable()`
    /// still fully completes and tears down the vault.
    func testDisableMaterializesBeforeDecryptingItemsAndAux() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let albumID = UUID()
        let albumFileName = LibraryAlbumStore.fileName(for: albumID)
        let albumPayload = try LibraryAlbumFile.encoder().encode(
            LibraryAlbumFile(id: albumID, name: "Favorites", createdAt: Date(timeIntervalSince1970: 0))
        )
        try albumPayload.write(to: dir.appendingPathComponent(albumFileName))

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")

        // Confirm the album file really was encrypted (the aux pass ran)
        // before exercising the reverse materialize+decrypt path against it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(albumFileName).path))

        try await coordinator.disable()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.jpeg")), Data("m1".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(albumFileName)), albumPayload)

        let state = await vault.state()
        XCTAssertEqual(state, .notConfigured)
    }

    /// End-to-end version of the completeness-guard regression fixed in
    /// `LibraryEncryptionMigrator`: a `.m` sidecar corrupted on disk (GCM-open
    /// fails) is silently dropped by `pendingEncryptedItemIDs()`'s
    /// `compactMap`, so before the fix, `decryptAll`'s post-loop recheck
    /// wouldn't see it either — `disable()` would trust the clean return and
    /// call `vault.teardown()`, discarding the DEK while this item's
    /// ciphertext sat unrecoverable on disk. Confirms through the actual
    /// `disable()` entry point (not just the migrator directly) that this
    /// can't happen: `disable()` throws, and critically the vault is NOT
    /// torn down.
    func testDisableDoesNotTearDownVaultWhenSidecarIsCorruptedOnDisk() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")

        guard let crypto = await vault.crypto() else {
            XCTFail("vault should be unlocked with a cached DEK after enable()")
            return
        }

        // Corrupt item 1's now-encrypted sidecar in place: garbage bytes, so
        // GCM-open fails. Its ciphertext media is left untouched.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let sidecarURL = store.metadataURL(itemID: 1)
        try Data("not a valid sealed box".utf8).write(to: sidecarURL, options: .atomic)

        do {
            try await coordinator.disable()
            XCTFail("expected disable() to throw when a ciphertext sidecar is corrupted on disk")
        } catch {
            // Expected.
        }

        if case .failed = coordinator.phase {
            // Expected.
        } else {
            XCTFail("expected phase to be .failed, got \(coordinator.phase)")
        }

        // The DEK must survive: vault still unlocked, NOT torn down.
        let stateAfter = await vault.state()
        XCTAssertEqual(stateAfter, .unlocked)
        let cryptoAfter = await vault.crypto()
        XCTAssertNotNil(cryptoAfter)

        // The corrupted sidecar file is still there — nothing was lost or
        // silently swept away.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: - Split enable (configureVault / runEnableMigration / isEnableIncomplete)

    /// `configureVault` returns the recovery key and unlocks the vault, but
    /// performs NO migration: the plaintext files are all still on disk and the
    /// pending-to-encrypt count is unchanged afterwards. This is the whole
    /// point of the split — the one-time key can be shown + acknowledged before
    /// any file is touched.
    func testConfigureVaultReturnsKeyWithoutMigrating() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)
        try seedPlaintext(dir, id: 2)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})

        let recovery = try await coordinator.configureVault(password: "pw")
        XCTAssertFalse(recovery.isEmpty)

        // Vault is configured + unlocked, but NOTHING was migrated.
        let state = await vault.state()
        XCTAssertEqual(state, .unlocked)
        XCTAssertEqual(coordinator.phase, .idle, "configureVault must not touch phase")
        for id in [1, 2] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path),
                          "plaintext sidecar \(id).json must survive configureVault")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).jpeg").path),
                          "plaintext media \(id).jpeg must survive configureVault")
        }

        // Pending-to-encrypt count is unchanged (both items still plaintext).
        let crypto = await vault.crypto()
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: try XCTUnwrap(crypto))
        XCTAssertEqual(migrator.pendingItemsAndAuxCount(), 2, "no items should have been migrated")
    }

    /// `runEnableMigration` is resumable: after a mid-migration failure it can
    /// be called again to finish, WITHOUT re-configuring the vault (re-running
    /// `configureVault` would throw `.malformed`, so a clean resume proves no
    /// re-configure) and WITHOUT re-migrating items already encrypted (their
    /// on-disk ciphertext must be byte-identical across the resume — a fresh
    /// re-encryption would use a new GCM nonce and change those bytes).
    func testRunEnableMigrationResumesAfterPartialFailure() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})

        let recovery = try await coordinator.configureVault(password: "pw")
        XCTAssertFalse(recovery.isEmpty)

        // Fully migrate item 1 first, so it is a genuinely already-encrypted
        // item on disk before any failure. Capture its RAW ciphertext sidecar
        // bytes (deterministic filename, random-nonce contents).
        try await coordinator.runEnableMigration()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))

        let cryptoOpt = await vault.crypto()
        let crypto = try XCTUnwrap(cryptoOpt)
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        let item1CiphertextURL = store.metadataURL(itemID: 1)
        let item1CiphertextBefore = try Data(contentsOf: item1CiphertextURL)

        // Add a new plaintext item 2 (good) plus a "bad" item 3 — a
        // full-decodable sidecar with NO media, so `migrateItem` throws
        // `.mediaMissing` and aborts the forward pass partway.
        try seedPlaintext(dir, id: 2)
        try Data("{\"schemaVersion\":5,\"itemID\":3,\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"3.jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}".utf8)
            .write(to: dir.appendingPathComponent("3.json"))

        // This pass must skip already-encrypted item 1 and fail on item 3.
        do {
            try await coordinator.runEnableMigration()
            XCTFail("expected runEnableMigration to throw on the bad item 3")
        } catch {
            XCTAssertEqual(error as? LibraryEncryptionMigrator.MigrateError, .mediaMissing)
        }
        if case .failed = coordinator.phase { /* expected */ } else {
            XCTFail("expected phase .failed after partial migration, got \(coordinator.phase)")
        }

        // minor4: item 1 was already migrated — this pass must have SKIPPED it,
        // not re-migrated it. Its plaintext is still absent and its ciphertext
        // sidecar is byte-identical (a re-encrypt would have changed the bytes).
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        XCTAssertEqual(try Data(contentsOf: item1CiphertextURL), item1CiphertextBefore,
                       "already-encrypted item 1 must be skipped on resume, not re-encrypted")
        // The bad item's plaintext is still present (it never migrated).
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("3.json").path))

        // Heal item 3 and resume — no re-configure (that would throw
        // `.malformed`).
        try Data("m3".utf8).write(to: dir.appendingPathComponent("3.jpeg"))
        try await coordinator.runEnableMigration()

        XCTAssertEqual(coordinator.phase, .idle)
        // Everything is now encrypted: no plaintext item sidecars remain, and
        // item 1's ciphertext STILL hasn't been rewritten across the resume.
        for id in [1, 2, 3] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).json").path),
                           "item \(id) should be encrypted after resume")
        }
        XCTAssertEqual(try Data(contentsOf: item1CiphertextURL), item1CiphertextBefore,
                       "already-encrypted item 1 must stay untouched through the full resume")
        // Vault is still the same configured, unlocked vault (never re-created).
        let state = await vault.state()
        XCTAssertEqual(state, .unlocked)
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        XCTAssertEqual(migrator.pendingItemsAndAuxCount(), 0)
    }

    /// `isEnableIncomplete` is false before the vault is ever configured, even
    /// with plaintext files pending.
    func testIsEnableIncompleteFalseWhenNotConfigured() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: makeVault(dir), rebuildIndex: {})
        let incomplete = await coordinator.isEnableIncomplete()
        XCTAssertFalse(incomplete)
    }

    /// `isEnableIncomplete` is true after `configureVault` but before
    /// migrating: the vault is configured + unlocked and plaintext still awaits
    /// encryption. This is what drives the Settings "Resume" affordance.
    func testIsEnableIncompleteTrueAfterConfigureBeforeMigration() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)
        try seedPlaintext(dir, id: 2)

        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: makeVault(dir), rebuildIndex: {})
        _ = try await coordinator.configureVault(password: "pw")

        let incomplete = await coordinator.isEnableIncomplete()
        XCTAssertTrue(incomplete)
    }

    /// `isEnableIncomplete` is false once a full enable has migrated every
    /// item (configured, unlocked, zero pending).
    func testIsEnableIncompleteFalseAfterFullEnable() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: makeVault(dir), rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")

        let incomplete = await coordinator.isEnableIncomplete()
        XCTAssertFalse(incomplete)
    }

    // MARK: - Resume direction (interrupted enable vs interrupted disable)

    /// After an interrupted DISABLE, `incompleteMigrationDirection()` must
    /// return `.disable` (from the persisted marker) — NOT `.enable`, even
    /// though item 1 has already been decrypted back to plaintext so the
    /// forward-pending count is > 0. A subsequent `disable()` (the resume) then
    /// completes and tears the vault down. This is the core of the fix: without
    /// the marker the mixed state would be misread as an interrupted enable and
    /// re-encrypt the Library the user was decrypting.
    func testInterruptedDisableResumesInDisableDirectionAndCompletes() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")

        guard let crypto = await vault.crypto() else {
            XCTFail("vault should be unlocked with a cached DEK after enable()")
            return
        }

        // Stray encrypted item 999: its sidecar decodes as the tiny `{ itemID }`
        // stub `pendingEncryptedItemIDs()` uses, but fails the full metadata
        // decode `decryptItem` needs — so `decryptAll` throws `.incomplete`.
        // `disable()` therefore aborts AFTER decrypting item 1 (verify-before-
        // delete) but WITHOUT tearing down, leaving the marker in place.
        let store = LibraryFileStore(itemsDirectory: dir, crypto: crypto)
        try store.writeMetadata(Data("{\"itemID\":999}".utf8), itemID: 999)
        try store.writeMedia(Data("pixels".utf8), itemID: 999, plaintextExtension: "jpeg")

        do {
            try await coordinator.disable()
            XCTFail("expected disable() to throw when decryptAll is incomplete")
        } catch {
            // Expected.
        }

        // Direction comes from the persisted marker → `.disable`, not `.enable`.
        let direction = await coordinator.incompleteMigrationDirection()
        XCTAssertEqual(direction, .disable)
        // Teardown correctly not reached: vault still configured + unlocked.
        let midState = await vault.state()
        XCTAssertEqual(midState, .unlocked)
        // The marker file really is on disk (next to vault.json).
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.disableInProgressMarkerURL.path))

        // Heal: drop the stray ciphertext item so a resumed disable can finish.
        store.removeItem(itemID: 999, plaintextExtension: "jpeg")

        // Resume in the SAME (disable) direction → completes + tears down.
        try await coordinator.disable()
        XCTAssertEqual(coordinator.phase, .idle)
        let finalState = await vault.state()
        XCTAssertEqual(finalState, .notConfigured)
        // Item 1's plaintext is intact; the marker is gone; nothing to resume.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.jpeg")), Data("m1".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.disableInProgressMarkerURL.path))
        let afterDirection = await coordinator.incompleteMigrationDirection()
        XCTAssertNil(afterDirection)
    }

    /// After an interrupted ENABLE (no disable marker was ever written, vault
    /// configured, plaintext still pending), `incompleteMigrationDirection()`
    /// returns `.enable`.
    func testInterruptedEnableResumesInEnableDirection() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)
        // Bad item 3: full-decodable sidecar with NO media → `migrateItem`
        // throws `.mediaMissing`, aborting the forward pass partway.
        try Data("{\"schemaVersion\":5,\"itemID\":3,\"canonicalPageURL\":\"x\",\"sourceDomain\":\"civitai.com\",\"originalCDNURL\":\"x\",\"mediaType\":\"image\",\"mediaFileName\":\"3.jpeg\",\"fileByteSize\":1,\"contentSHA256\":\"a\",\"width\":1,\"height\":1,\"nsfwLevel\":1,\"author\":{},\"albumIDs\":[],\"savedAt\":\"2026-01-01T00:00:00Z\",\"savedByAppVersion\":\"t\"}".utf8)
            .write(to: dir.appendingPathComponent("3.json"))

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})
        do {
            _ = try await coordinator.enable(password: "pw")
            XCTFail("expected enable() to throw on the bad item")
        } catch {
            // Expected.
        }

        let direction = await coordinator.incompleteMigrationDirection()
        XCTAssertEqual(direction, .enable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.disableInProgressMarkerURL.path))
    }

    /// A clean full disable removes the marker, so a LATER fresh enable is read
    /// as `.enable` (not misclassified as an interrupted disable from a stale
    /// marker).
    func testCleanDisableRemovesMarkerSoLaterConfigureResumesAsEnable() async throws {
        let dir = try makeTempDir()
        try seedPlaintext(dir, id: 1)

        let vault = makeVault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: vault, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")
        try await coordinator.disable()

        // Clean disable: marker removed, nothing to resume, vault torn down.
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.disableInProgressMarkerURL.path))
        let afterDisable = await coordinator.incompleteMigrationDirection()
        XCTAssertNil(afterDisable)

        // A later fresh enable (configure only) reads as `.enable`, proving no
        // stale marker lingered to misclassify it as an interrupted disable.
        _ = try await coordinator.configureVault(password: "pw2")
        let afterConfigure = await coordinator.incompleteMigrationDirection()
        XCTAssertEqual(afterConfigure, .enable)
    }
}
