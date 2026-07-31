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
}
