import XCTest
import CryptoKit
@testable import Diffusely

@MainActor
final class LibraryCustomEncryptionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(_ directory: URL, id: Int = 1) throws -> Data {
        let metadata = LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion, itemID: id,
            sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "https://example.com/images/\(id)", sourceDomain: "example.com",
            originalCDNURL: "https://example.com/original=true/\(id).jpeg", mediaType: .image,
            mediaFileName: "\(id).jpeg", fileByteSize: 5, contentSHA256: "synthetic",
            width: 1, height: 1, nsfwLevel: 1, author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: nil, publishedAt: nil, albumIDs: [],
            savedAt: Date(), savedByAppVersion: "test")
        let data = try LibraryItemMetadata.encoder().encode(metadata)
        let store = LibraryFileStore(itemsDirectory: directory, crypto: nil, createsContainerDirectory: false)
        try store.writeMedia(Data("image".utf8), itemID: id, plaintextExtension: "jpeg")
        try store.writeMetadata(data, itemID: id)
        return data
    }

    private func vault(_ directory: URL, keys: LibraryKeyStore = InMemoryKeyStore()) -> LibraryVault {
        LibraryVault(vaultURL: directory.appendingPathComponent("vault.json"),
                     backupURL: directory.appendingPathComponent("vault.backup.json"),
                     keyStore: keys, rounds: 1000)
    }

    private func container(_ directory: URL) async -> LibraryContainer {
        let name = "LibraryCustomEncryptionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let container = LibraryContainer(rootStore: LibraryRootStore(defaults: defaults))
        await container.setRoot(.custom(directory))
        defaults.removePersistentDomain(forName: name)
        return container
    }

    func testCustomLibraryEnableReopenAndDisableRoundTrip() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = try seed(dir)
        let album = LibraryAlbumFile(id: UUID(), name: "Synthetic album", createdAt: Date())
        let plain = LibraryFileStore(itemsDirectory: dir, crypto: nil, createsContainerDirectory: false)
        let albumName = "album-\(album.id.uuidString).json"
        let albumData = try LibraryAlbumFile.encoder().encode(album)
        try plain.writeAux(albumData, name: albumName)
        try Data("keep".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let container = await container(dir)
        let keys = InMemoryKeyStore()
        let provider = LibraryVaultProvider(container: container, keyStore: keys)
        await provider.bootstrap()
        XCTAssertEqual(provider.libraryGate, .browsable)
        _ = try await provider.enableConfigure(password: "test-password")
        XCTAssertEqual(provider.libraryGate, .setupIncomplete)
        try await provider.runEnableMigration()
        XCTAssertEqual(provider.libraryGate, .browsable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(LibraryChangeJournal.directoryName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("vault.json").path))
        let rootStore = LibraryRootStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertNil(rootStore.validate(dir, iCloudItemsDirectory: nil))
        let store = await provider.fileStore()
        XCTAssertTrue(store.isEncrypted)
        XCTAssertFalse(store.createsContainerDirectory)
        XCTAssertEqual(store.readMetadata(itemID: 1), metadata)
        XCTAssertEqual(store.readAux(name: albumName), albumData)

        let reopened = LibraryVaultProvider(container: container, keyStore: keys)
        await reopened.bootstrap()
        XCTAssertEqual(reopened.libraryGate, .locked)
        let reopenedVault = try XCTUnwrap(reopened.vault)
        try await reopenedVault.unlock(password: "test-password")
        await reopened.refreshState()
        XCTAssertEqual(reopened.libraryGate, .browsable)
        try await reopened.disableEncryption()
        XCTAssertEqual(reopened.libraryGate, .browsable)
        let state = await reopenedVault.state()
        XCTAssertEqual(state, .notConfigured)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(albumName)), albumData)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.jpeg")), Data("image".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("notes.txt")), Data("keep".utf8))
    }

    func testEncryptedLibraryCopiesBetweenCustomAndICloudLayoutsWithoutRearrangement() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let share = parent.appendingPathComponent("share")
        let cloudItems = parent.appendingPathComponent("iCloud/Documents/Items")
        let copiedBack = parent.appendingPathComponent("copied-back")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudItems.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata = try seed(share)
        let shareContainer = await container(share)
        let source = LibraryVaultProvider(container: shareContainer, keyStore: InMemoryKeyStore())
        await source.bootstrap()
        let recovery = try await source.enableConfigure(password: "portable")
        try await source.runEnableMigration()

        // Copy the complete folder without moving individual vault/item files.
        try FileManager.default.copyItem(at: share, to: cloudItems)
        let defaults = UserDefaults(suiteName: "LibraryCustomEncryptionTests-\(UUID().uuidString)")!
        let cloudContainer = LibraryContainer(rootStore: LibraryRootStore(defaults: defaults),
                                              resolvedICloudItemsDirectory: cloudItems)
        let cloud = LibraryVaultProvider(container: cloudContainer, keyStore: InMemoryKeyStore())
        await cloud.bootstrap()
        XCTAssertEqual(cloud.libraryGate, .locked)
        let cloudVault = try XCTUnwrap(cloud.vault)
        try await cloudVault.unlock(password: "portable")
        await cloud.refreshState()
        XCTAssertEqual(cloud.libraryGate, .browsable)
        let cloudStore = await cloud.fileStore()
        XCTAssertEqual(cloudStore.readMetadata(itemID: 1), metadata)
        XCTAssertEqual(cloudStore.readMedia(itemID: 1, plaintextExtension: "jpeg"), Data("image".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            cloudItems.deletingLastPathComponent().appendingPathComponent("vault.json").path))

        try FileManager.default.copyItem(at: cloudItems, to: copiedBack)
        let returnContainer = await container(copiedBack)
        let returned = LibraryVaultProvider(container: returnContainer, keyStore: InMemoryKeyStore())
        await returned.bootstrap()
        XCTAssertEqual(returned.libraryGate, .locked)
        let returnVault = try XCTUnwrap(returned.vault)
        try await returnVault.unlock(recoveryKey: recovery)
        await returned.refreshState()
        XCTAssertEqual(returned.libraryGate, .browsable)
        let returnedStore = await returned.fileStore()
        XCTAssertEqual(returnedStore.readMetadata(itemID: 1), metadata)
        XCTAssertEqual(returnedStore.readMedia(itemID: 1, plaintextExtension: "jpeg"), Data("image".utf8))
        for name in try FileManager.default.contentsOfDirectory(atPath: share.path) {
            let original = try Data(contentsOf: share.appendingPathComponent(name))
            XCTAssertEqual(try Data(contentsOf: cloudItems.appendingPathComponent(name)), original)
            XCTAssertEqual(try Data(contentsOf: copiedBack.appendingPathComponent(name)), original)
        }
    }

    func testSwitchingEncryptedLibrariesReplacesCoordinatorAndKeepsKeysSeparate() async throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        _ = try seed(a)
        _ = try seed(b, id: 2)
        let container = await container(a)
        let provider = LibraryVaultProvider(container: container, keyStore: InMemoryKeyStore())
        await provider.bootstrap()
        _ = try await provider.enableConfigure(password: "a")
        try await provider.runEnableMigration()
        let coordinatorA = await provider.encryptionCoordinator()
        let vaultA = try XCTUnwrap(provider.vault)
        await container.setRoot(.custom(b))
        await provider.rebootstrap()
        let oldState = await vaultA.state()
        XCTAssertEqual(oldState, .locked)
        let coordinatorB = await provider.encryptionCoordinator()
        XCTAssertFalse(coordinatorA === coordinatorB)
        _ = try await provider.enableConfigure(password: "b")
        try await provider.runEnableMigration()
        await container.setRoot(.custom(a))
        await provider.rebootstrap()
        XCTAssertEqual(provider.libraryGate, .locked)
        let reopened = try XCTUnwrap(provider.vault)
        let unlocked = await reopened.unlockWithBiometrics()
        XCTAssertTrue(unlocked)
        await provider.refreshState()
        try await provider.disableEncryption()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("2.json").path))
        let secondVault = vault(b)
        try await secondVault.unlock(password: "b")
        let secondCrypto = await secondVault.crypto()
        XCTAssertNotNil(secondCrypto)
    }

    func testDisconnectedForwardMigrationDoesNotRecreateFolderAndCanResume() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("library"), moved = parent.appendingPathComponent("disconnected")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try seed(dir); _ = try seed(dir, id: 2)
        let v = vault(dir)
        _ = try await v.configure(password: "pw")
        let cryptoValue = await v.crypto()
        let crypto = try XCTUnwrap(cryptoValue)
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: crypto)
        XCTAssertThrowsError(try migrator.migrateAll { done, _ in
            if done == 1 { try! FileManager.default.moveItem(at: dir, to: moved) }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("vault.json").path))
        try FileManager.default.moveItem(at: moved, to: dir)
        try migrator.migrateAll { _, _ in }
        try migrator.verifyNoPlaintextRemains()
    }

    func testDisableMarkerInsideItemsIsRecognizedAndCleaned() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let items = parent.appendingPathComponent("Items")
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: false)
        let v = vault(items)
        let marker = v.disableInProgressMarkerURL
        // A previous disable finished removing the vault but left its marker.
        try Data("disabling".utf8).write(to: marker)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: items, vault: v, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // An interrupted disable with no remaining items must still show Resume.
        try Data("disabling".utf8).write(to: marker)
        let provider = LibraryVaultProvider(vault: v, itemsDirectory: items)
        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .setupIncomplete)
        let direction = await coordinator.incompleteMigrationDirection()
        XCTAssertEqual(direction, .disable)
        try await coordinator.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testOrphanedEncryptedMediaPreventsVaultTeardown() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = vault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: v, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")
        let cryptoValue = await v.crypto()
        let store = LibraryFileStore(itemsDirectory: dir, crypto: try XCTUnwrap(cryptoValue),
                                     createsContainerDirectory: false)
        try store.writeMedia(Data("orphan".utf8), itemID: 7, plaintextExtension: "jpeg")
        do { try await coordinator.disable(); XCTFail("Orphaned ciphertext must retain its vault") }
        catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("vault.json").path))
        XCTAssertEqual(store.readMedia(itemID: 7, plaintextExtension: "jpeg"), Data("orphan".utf8))
    }

    func testDisconnectedReverseMigrationPreservesVaultAndCanResume() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("library"), moved = parent.appendingPathComponent("disconnected")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try seed(dir); _ = try seed(dir, id: 2)
        let v = vault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: v, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")
        let cryptoValue = await v.crypto()
        let migrator = LibraryEncryptionMigrator(itemsDirectory: dir, crypto: try XCTUnwrap(cryptoValue))
        try Data("disabling".utf8).write(to: dir.appendingPathComponent("vault.disabling"))
        XCTAssertThrowsError(try migrator.decryptAll { done, _ in
            if done == 1 { try! FileManager.default.moveItem(at: dir, to: moved) }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        do { try await coordinator.disable(); XCTFail("Disconnected storage must not complete teardown") }
        catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("vault.json").path))
        try FileManager.default.moveItem(at: moved, to: dir)
        let reopened = vault(dir)
        try await reopened.unlock(password: "pw")
        let resumed = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: reopened, rebuildIndex: {})
        let direction = await resumed.incompleteMigrationDirection()
        XCTAssertEqual(direction, .disable)
        try await resumed.disable()
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("1.jpeg")), Data("image".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("2.jpeg")), Data("image".utf8))
    }

    func testDisableCannotStartWithoutDurableDirectionMarker() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try seed(dir)
        let v = vault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: v, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("vault.disabling"), withIntermediateDirectories: true)
        do { try await coordinator.disable(); XCTFail("Should fail before decryption") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1.json").path))
        let state = await v.state()
        XCTAssertEqual(state, .unlocked)
    }

    func testOrphanedCiphertextNeverBootstrapsAsPlaintext() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("sealed".utf8).write(to: dir.appendingPathComponent("opaque.b"))
        let provider = LibraryVaultProvider(container: await container(dir), keyStore: InMemoryKeyStore())
        await provider.bootstrap()
        XCTAssertEqual(provider.libraryGate, .rootUnavailable(dir))
        XCTAssertNil(provider.vault)
    }
    func testBiometricKeysAreScopedAndWrongKeyIsRejected() async throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let keys = InMemoryKeyStore()
        let first = vault(a, keys: keys), second = vault(b, keys: keys)
        _ = try await first.configure(password: "a")
        _ = try await second.configure(password: "b")
        await first.lock(); await second.lock()
        let firstUnlock = await first.unlockWithBiometrics()
        let secondUnlock = await second.unlockWithBiometrics()
        XCTAssertTrue(firstUnlock); XCTAssertTrue(secondUnlock)
        let file = try JSONDecoder().decode(LibraryVaultFile.self, from: Data(contentsOf: a.appendingPathComponent("vault.json")))
        await first.lock()
        try keys.store(dek: Data(repeating: 0, count: 32), vaultID: file.identity)
        let wrongUnlock = await first.unlockWithBiometrics()
        XCTAssertFalse(wrongUnlock)
        let state = await first.state()
        XCTAssertEqual(state, .locked)
        try await second.teardown()
        // Clearing one vault does not clear another vault's entry.
        let retained = try await keys.loadWithBiometrics(reason: "test", vaultID: file.identity)
        XCTAssertNotNil(retained)
    }

    func testLegacyVaultUpgradesAfterPasswordUnlockAndSurvivesMove() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("old"), moved = parent.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = InMemoryKeyStore()
        let original = vault(dir, keys: keys)
        let recovery = try await original.configure(password: "old-password")
        let url = dir.appendingPathComponent("vault.json")
        var legacy = try JSONDecoder().decode(LibraryVaultFile.self, from: Data(contentsOf: url))
        legacy.keyCheck = nil
        let bytes = try JSONEncoder().encode(legacy)
        try bytes.write(to: url)
        try bytes.write(to: dir.appendingPathComponent("vault.backup.json"))
        let reopened = vault(dir, keys: keys)
        let beforeUpgrade = await reopened.unlockWithBiometrics()
        XCTAssertFalse(beforeUpgrade)
        try await reopened.unlock(password: "old-password")
        try await reopened.changePassword(old: "old-password", new: "new-password")
        try FileManager.default.moveItem(at: dir, to: moved)
        let relocated = vault(moved, keys: keys)
        let afterMove = await relocated.unlockWithBiometrics()
        XCTAssertTrue(afterMove)
        await relocated.lock()
        try await relocated.unlock(recoveryKey: recovery)
        let state = await relocated.state()
        XCTAssertEqual(state, .unlocked)
    }

    func testBackupVaultAloneCanOpenCustomLibrary() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try seed(dir)
        let v = vault(dir)
        let coordinator = LibraryEncryptionCoordinator(itemsDirectory: dir, vault: v, rebuildIndex: {})
        _ = try await coordinator.enable(password: "pw")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("vault.json"))
        let provider = LibraryVaultProvider(container: await container(dir), keyStore: InMemoryKeyStore())
        await provider.bootstrap()
        XCTAssertEqual(provider.libraryGate, .locked)
        let reopened = try XCTUnwrap(provider.vault)
        try await reopened.unlock(password: "pw")
        await provider.refreshState()
        XCTAssertEqual(provider.libraryGate, .browsable)
    }

    func testRootSwitchIsRejectedIfEncryptionStartsDuringValidation() async {
        var maySwitch = true
        var beganSwitch = false
        let coordinator = LibraryRootCoordinator(dependencies: .init(
            validate: { _ in maySwitch = false; return nil },
            beginSwitch: { beganSwitch = true }, quiesce: {}, applyRoot: { _ in },
            rebootstrapVault: {}, wipeIndex: {}, rebuildIndex: { .scanned },
            restartStore: {}, endSwitch: {}, reportUnavailable: { _ in },
            canSwitch: { maySwitch }))
        let error = await coordinator.switchTo(.custom(URL(fileURLWithPath: "/tmp/example")))
        XCTAssertEqual(error, .encryptionInProgress)
        XCTAssertFalse(beganSwitch)
    }

}
