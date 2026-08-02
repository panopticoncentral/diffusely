import Testing
import Foundation
import CryptoKit
@testable import Diffusely

/// BE-a (before-enable hardening): `LibrarySaveService.performSave` must
/// never write plaintext into a configured-but-locked encrypted container.
/// Its `resolveVaultContext` seam (mirrors `LibraryAlbumService` /
/// `FileLibraryBackfillSidecarStore`) lets these tests drive
/// `.locked`/`.unlocked`/`.notConfigured` directly instead of the
/// process-wide `LibraryVaultProvider.shared` singleton — driving the real
/// singleton into `.locked` would leak into every other test in the process
/// (see the precedent documented on `LibraryIndexEncryptedTests`).
///
/// `performSave` is exercised directly (it's `internal`, not `private`,
/// specifically so tests can reach it) rather than through the
/// fire-and-forget `save()` wrapper, and every save here uses a CDN URL that
/// fails `URL(string:)` parsing. That keeps these tests deterministic and
/// network-free: whichever of the two throws — the new locked guard, or the
/// pre-existing invalid-URL check right after it — happens before
/// `performSave` ever reaches the real network download, so no mocking is
/// needed to prove the guard's placement and behavior.
@Suite @MainActor struct LibrarySaveServiceTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImage(id: Int) -> CivitaiImage {
        CivitaiImage(
            id: id, url: "uuid-\(id)", width: 10, height: 10,
            nsfwLevel: 1, type: "image", postId: nil, user: nil, stats: nil
        )
    }

    private let author = LibraryAuthor(id: nil, username: nil, avatarURL: nil)

    // MARK: - Locked vault: refused

    @Test func performSaveRefusesAndWritesNothingWhenLocked() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = LibrarySaveService(resolveVaultContext: {
            (.locked, LibraryFileStore(itemsDirectory: dir, crypto: nil))
        })
        let image = makeImage(id: 101)

        await #expect(throws: LibraryBackfillSidecarStoreError.vaultLocked) {
            try await svc.performSave(
                itemID: image.id, image: image, originalCDNURL: image.originalURL,
                canonicalPageURL: "https://civitai.com/images/101", canonicalPostURL: nil,
                knownPostTitle: nil, knownPublishedAt: nil, sourceDomain: "civitai.com",
                mediaType: .image, author: author
            )
        }

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.isEmpty, "a locked save must leave nothing on disk")
    }

    // MARK: - .notConfigured / .unlocked: unaffected by the new guard

    @Test func performSaveProceedsPastGuardWhenNotConfigured() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = LibrarySaveService(resolveVaultContext: {
            (.notConfigured, LibraryFileStore(itemsDirectory: dir, crypto: nil))
        })
        let image = makeImage(id: 102)

        // Empty string fails `URL(string:)` deterministically (no network),
        // so reaching `.downloadFailed` — not `.vaultLocked` — proves the
        // guard let a `.notConfigured` save through unchanged.
        do {
            try await svc.performSave(
                itemID: image.id, image: image, originalCDNURL: "",
                canonicalPageURL: "https://civitai.com/images/102", canonicalPostURL: nil,
                knownPostTitle: nil, knownPublishedAt: nil, sourceDomain: "civitai.com",
                mediaType: .image, author: author
            )
            Issue.record("expected LibrarySaveError.downloadFailed")
        } catch LibrarySaveError.downloadFailed {
            // Expected: control reached the pre-existing URL-parsing step,
            // i.e. the guard did not newly refuse this save.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test func performSaveProceedsPastGuardWhenUnlocked() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let crypto = LibraryFileCrypto(dek: SymmetricKey(size: .bits256))
        let svc = LibrarySaveService(resolveVaultContext: {
            (.unlocked, LibraryFileStore(itemsDirectory: dir, crypto: crypto))
        })
        let image = makeImage(id: 103)

        do {
            try await svc.performSave(
                itemID: image.id, image: image, originalCDNURL: "",
                canonicalPageURL: "https://civitai.com/images/103", canonicalPostURL: nil,
                knownPostTitle: nil, knownPublishedAt: nil, sourceDomain: "civitai.com",
                mediaType: .image, author: author
            )
            Issue.record("expected LibrarySaveError.downloadFailed")
        } catch LibrarySaveError.downloadFailed {
            // Expected: an unlocked vault is never refused either.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - LibrarySaveError helpers

    @Test func libraryLockedErrorExposesHelpers() {
        let locked = LibrarySaveError.libraryLocked
        #expect(locked.isLibraryLocked)
        #expect(locked.alertTitle == "Library Locked")
        #expect(locked.errorDescription == "Your Library is locked. Unlock it to save.")
    }

    @Test func nonLockedErrorsAreNotLockedAndHaveTitles() {
        #expect(!LibrarySaveError.alreadySaved.isLibraryLocked)
        #expect(LibrarySaveError.alreadySaved.alertTitle == "Already Saved")
        #expect(LibrarySaveError.downloadFailed.alertTitle == "Download Failed")
        #expect(LibrarySaveError.writeFailed(LibrarySaveError.downloadFailed).alertTitle == "Couldn't Save")
    }

    // MARK: - Failure recording + pending-retry queue

    @Test func recordFailureQueuesPendingAndSetsLockedError() {
        let svc = LibrarySaveService()
        let image = makeImage(id: 301)

        svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                          image: image, knownPostTitle: "My Post", knownPublishedAt: nil)

        #expect(svc.lastError?.isLibraryLocked == true)
        #expect(svc.pendingLockedSaves.count == 1)
        #expect(svc.pendingLockedSaves.first?.image.id == 301)
        #expect(svc.pendingLockedSaves.first?.knownPostTitle == "My Post")
    }

    @Test func recordFailureDoesNotDuplicatePendingForSameItem() {
        let svc = LibrarySaveService()
        let image = makeImage(id: 302)

        svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                          image: image, knownPostTitle: nil, knownPublishedAt: nil)
        svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                          image: image, knownPostTitle: nil, knownPublishedAt: nil)

        #expect(svc.pendingLockedSaves.count == 1)
    }

    @Test func recordFailureMapsNonLockedErrorsWithoutQueuing() {
        let svc = LibrarySaveService()
        let image = makeImage(id: 303)

        svc.recordFailure(LibrarySaveError.downloadFailed,
                          image: image, knownPostTitle: nil, knownPublishedAt: nil)
        #expect(svc.lastError?.alertTitle == "Download Failed")
        #expect(svc.pendingLockedSaves.isEmpty)

        let generic = NSError(domain: "test", code: 1)
        svc.recordFailure(generic, image: image, knownPostTitle: nil, knownPublishedAt: nil)
        #expect(svc.lastError?.alertTitle == "Couldn't Save")
        #expect(svc.pendingLockedSaves.isEmpty)
    }

    @Test func discardAndClearBehaveIndependently() {
        let svc = LibrarySaveService()
        let image = makeImage(id: 304)
        svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                          image: image, knownPostTitle: nil, knownPublishedAt: nil)

        svc.clearError()
        #expect(svc.lastError == nil)
        #expect(svc.pendingLockedSaves.count == 1, "clearError leaves the retry queue intact")

        svc.discardPendingLockedSaves()
        #expect(svc.pendingLockedSaves.isEmpty)
    }

    @Test func retryPendingLockedSavesDrainsQueueAndRefires() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Inject `.locked` so the re-fired save's performSave refuses BEFORE any
        // network download (the locked guard precedes the download). Assertions run
        // synchronously, before the fire-and-forget task body executes.
        //
        // NOTE: the re-fired save() spawns an unstructured Task (performSave) that
        // awaits LibraryContainer.shared.itemsDirectory() before hitting the locked
        // guard. That task cannot run until this @MainActor method suspends, so the
        // synchronous assertions below are unaffected; the straggler no-ops via the
        // locked guard (and [weak self] once `svc` deallocates).
        let svc = LibrarySaveService(resolveVaultContext: {
            (.locked, LibraryFileStore(itemsDirectory: dir, crypto: nil))
        })
        let image = makeImage(id: 305)
        svc.recordFailure(LibraryBackfillSidecarStoreError.vaultLocked,
                          image: image, knownPostTitle: nil, knownPublishedAt: nil)
        #expect(svc.pendingLockedSaves.count == 1)

        svc.retryPendingLockedSaves()

        #expect(svc.pendingLockedSaves.isEmpty, "retry drains the queue synchronously")
        #expect(svc.lastError == nil, "retry clears the previous error")
        #expect(svc.isSaving(itemID: 305), "retry re-initiates the save (inFlight synchronously)")
    }
}
