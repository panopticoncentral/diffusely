import Foundation

/// One-time, resumable, loss-safe conversion of a plaintext Library container
/// to encrypted opaque files. Per item, order matters for crash-safety:
/// encrypt media → encrypt sidecar → verify both decrypt back to the exact
/// plaintext bytes → only then delete the plaintext media, then the
/// plaintext sidecar. A crash or termination at ANY point — including
/// between those two final deletes — leaves the item resumable with no data
/// loss: `pendingItemIDs()` will surface it again (or, if the ciphertext was
/// already fully written and verified and only the sidecar delete didn't
/// complete, `migrateItem` self-heals the leftover plaintext sidecar instead
/// of mistaking it for a real failure — see `isAlreadyMigrated`). Re-running
/// is always safe; already-migrated items are a no-op.
///
/// Album files (`album-<uuid>.json`) and the sort-assistant state file
/// (`sort-assistant-state.json`) are migrated the same verify-before-delete
/// way, in an aux pass that runs after all items. (Aux files have no
/// equivalent orphan window: each is a single file with a single final
/// delete, not a pair.)
///
/// The reverse direction (`decryptItem`/`decryptAll`, for disabling
/// encryption) mirrors all of this exactly, backwards: decrypt media +
/// sidecar → write plaintext media, then plaintext sidecar → verify both
/// round-trip → only then delete the ciphertext (both files, via
/// `LibraryFileStore.removeItem`). A crash before that final delete leaves
/// plaintext written+verified with the ciphertext still present;
/// `pendingEncryptedItemIDs()` finds the item again and `decryptItem`
/// recognizes the already-correct plaintext and self-heals by removing the
/// leftover ciphertext instead of re-writing or throwing — see
/// `isAlreadyDecrypted`. `decryptAux` mirrors `migrateAux` the same way for
/// album files and sort-assistant state.
struct LibraryEncryptionMigrator {
    let itemsDirectory: URL
    let crypto: LibraryFileCrypto

    /// Test-only seam: when set, the post-write verification reads (inside
    /// `migrateItem`, `decryptItem`, `decryptAux`) go through a store built
    /// from THIS crypto instead of `crypto` — deliberately mismatched, so the
    /// decrypt round-trip fails deterministically, exercising the
    /// `.verifyFailed` path without needing a real storage fault or a race.
    /// Always nil in production; every real call site uses the two-argument
    /// initializer and never touches this field.
    var verifyCryptoOverride: LibraryFileCrypto? = nil

    enum MigrateError: Error, Equatable {
        /// Forward: the plaintext sidecar exists but its media file does
        /// not, AND the item has no matching verified ciphertext already on
        /// disk (i.e. this isn't the crash-orphan `isAlreadyMigrated`
        /// self-heals) — the item can't be safely encrypted, so the sidecar
        /// is left in place.
        /// Reverse: the ciphertext sidecar exists but its ciphertext media
        /// does not — the item can't be safely decrypted, so the ciphertext
        /// is left in place. (Reverse's crash-orphan cases are disambiguated
        /// before this point — see `isAlreadyDecrypted` and
        /// `isMetadataOnlyCrashOrphan` — so this is always a genuine
        /// failure.)
        case mediaMissing
        /// The just-written file(s) didn't round-trip back to the original
        /// bytes — the source representation (plaintext, or ciphertext) is
        /// left in place so no data is lost.
        case verifyFailed
        /// `decryptAll` completed both passes without any individual item or
        /// aux file throwing, but a post-loop re-check still found
        /// ciphertext present — meaning some `decryptItem`/`decryptAux` call
        /// silently no-op'd rather than converting or throwing (the known
        /// way this happens: a sidecar that decodes fine as the tiny
        /// `{ itemID }` stub `pendingEncryptedItemIDs()` uses, but fails the
        /// FULL `LibraryItemMetadata` decode `decryptItem` needs to learn
        /// the extension). This is the hard guarantee a caller (e.g. the
        /// disable-encryption coordinator, before discarding the DEK) needs:
        /// a non-throwing `decryptAll()` return means zero ciphertext
        /// remains; this case means it doesn't, so the DEK must NOT be
        /// discarded yet.
        case incomplete
    }

    private var encryptedStore: LibraryFileStore {
        LibraryFileStore(itemsDirectory: itemsDirectory, crypto: crypto)
    }

    /// The store used for the post-write verification reads. Identical to
    /// `encryptedStore` in production (`verifyCryptoOverride` is nil); see
    /// that property's doc comment.
    private var verifyStore: LibraryFileStore {
        LibraryFileStore(itemsDirectory: itemsDirectory, crypto: verifyCryptoOverride ?? crypto)
    }

    // MARK: Items

    /// Plaintext item ids still awaiting migration: every `<int>.json` in the
    /// directory, excluding album files (`album-*.json`) and any other
    /// non-integer-stem JSON (e.g. `sort-assistant-state.json`).
    func pendingItemIDs() -> [Int] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: itemsDirectory.path)) ?? []
        return files.compactMap { name -> Int? in
            guard name.hasSuffix(".json"), !name.hasPrefix(LibraryAlbumStore.fileNamePrefix) else { return nil }
            return Int((name as NSString).deletingPathExtension)
        }
    }

    /// Migrates one item. Idempotent: if the plaintext sidecar is already
    /// gone (a prior run finished it), this is a no-op.
    func migrateItem(itemID: Int, plaintextExtension ext: String) throws {
        let sidecarURL = itemsDirectory.appendingPathComponent("\(itemID).json")
        let mediaURL = itemsDirectory.appendingPathComponent("\(itemID).\(ext)")
        guard let sidecar = try? Data(contentsOf: sidecarURL) else { return }   // already migrated

        guard let media = try? Data(contentsOf: mediaURL) else {
            // Plaintext sidecar present, plaintext media absent: either a
            // genuinely incomplete/corrupt item, or a crash-orphan left by a
            // prior run killed between this function's two final deletes
            // (plaintext media already removed, plaintext sidecar not yet) —
            // in that case the item is ALREADY fully encrypted and verified,
            // so self-heal by cleaning up the leftover plaintext instead of
            // throwing and wedging every future migrateAll() on this item.
            if isAlreadyMigrated(itemID: itemID, sidecar: sidecar) {
                removeCrashOrphanPlaintext(itemID: itemID, sidecarURL: sidecarURL)
                return
            }
            throw MigrateError.mediaMissing
        }

        try encryptedStore.writeMedia(media, itemID: itemID, plaintextExtension: ext)
        try encryptedStore.writeMetadata(sidecar, itemID: itemID)

        // Verify decrypt round-trips (through `verifyStore`, see its doc
        // comment) before deleting anything.
        guard verifyStore.readMedia(itemID: itemID, plaintextExtension: ext) == media,
              verifyStore.readMetadata(itemID: itemID) == sidecar else {
            throw MigrateError.verifyFailed
        }

        try FileManager.default.removeItem(at: mediaURL)
        try FileManager.default.removeItem(at: sidecarURL)
    }

    /// True when this item's ciphertext already exists and its decrypted
    /// metadata matches `sidecar` byte-for-byte — the signal that this is
    /// the crash-orphan case (media already deleted, sidecar left behind by
    /// an interrupted prior run) rather than a genuinely incomplete item.
    /// Always checked against the REAL `encryptedStore` (never
    /// `verifyCryptoOverride`, which only affects `migrateItem`'s own
    /// verify-before-delete step). Encrypted mode's media/metadata URLs are
    /// derived purely from the crypto token, not `plaintextExtension` — any
    /// extension value is fine for this existence/match check.
    private func isAlreadyMigrated(itemID: Int, sidecar: Data) -> Bool {
        encryptedStore.readMetadata(itemID: itemID) == sidecar
            && encryptedStore.readMedia(itemID: itemID, plaintextExtension: "jpeg") != nil
    }

    /// Best-effort crash-orphan cleanup: removes the leftover plaintext
    /// sidecar and any leftover plaintext media under either known
    /// extension (defensive — by the time this runs the media file for
    /// `ext` is already confirmed absent, but a stray file under the other
    /// extension is cheap to also sweep). Errors are swallowed: worst case,
    /// the next run's `pendingItemIDs()` finds the same orphan again and
    /// retries the cleanup.
    private func removeCrashOrphanPlaintext(itemID: Int, sidecarURL: URL) {
        try? FileManager.default.removeItem(at: sidecarURL)
        for knownExt in ["jpeg", "mp4"] {
            try? FileManager.default.removeItem(at: itemsDirectory.appendingPathComponent("\(itemID).\(knownExt)"))
        }
    }

    // MARK: Aux (album files, sort-assistant state)

    /// Plaintext aux files still awaiting migration: every `album-*.json`
    /// file present, plus `sort-assistant-state.json` if present.
    private func pendingAuxNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: itemsDirectory.path)) ?? []
        var names = files.filter {
            $0.hasPrefix(LibraryAlbumStore.fileNamePrefix) && $0.hasSuffix(".json")
        }
        if files.contains(SortAssistantStateStore.fileName) {
            names.append(SortAssistantStateStore.fileName)
        }
        return names
    }

    /// Migrates one aux file, located by its literal plaintext name (e.g.
    /// `album-<uuid>.json`, `sort-assistant-state.json`), the same
    /// verify-before-delete way as `migrateItem`. Idempotent: a missing
    /// plaintext file (already migrated) is a no-op.
    private func migrateAux(name: String) throws {
        let plaintextURL = itemsDirectory.appendingPathComponent(name)
        guard let payload = try? Data(contentsOf: plaintextURL) else { return }   // already migrated

        try encryptedStore.writeAux(payload, name: name)

        guard encryptedStore.readAux(name: name) == payload else {
            throw MigrateError.verifyFailed
        }

        try FileManager.default.removeItem(at: plaintextURL)
    }

    // MARK: All

    /// Migrates every pending item, then every pending aux file, reporting
    /// cumulative `(done, total)` progress across both passes as each
    /// completes. Stops (throwing) on the first failure, leaving whatever
    /// hasn't been reached yet untouched and resumable.
    func migrateAll(progress: (Int, Int) -> Void) throws {
        let itemIDs = pendingItemIDs()
        let auxNames = pendingAuxNames()
        let total = itemIDs.count + auxNames.count
        var done = 0

        for id in itemIDs {
            try migrateItem(itemID: id, plaintextExtension: mediaExtension(forItemID: id))
            done += 1
            progress(done, total)
        }

        for name in auxNames {
            try migrateAux(name: name)
            done += 1
            progress(done, total)
        }
    }

    /// Resolves an item's plaintext media extension from its sidecar's
    /// `mediaType` (authoritative); falls back to checking which media file
    /// is actually present when the sidecar can't be decoded.
    private func mediaExtension(forItemID id: Int) -> String {
        if let data = try? Data(contentsOf: itemsDirectory.appendingPathComponent("\(id).json")),
           let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data) {
            return meta.mediaType.fileExtension
        }
        return FileManager.default.fileExists(atPath: itemsDirectory.appendingPathComponent("\(id).mp4").path) ? "mp4" : "jpeg"
    }

    // MARK: All, materializing evicted plaintext first

    /// Best-effort iCloud materialize for one item's plaintext media before
    /// `migrateAllMaterializing` encrypts it. A large library evicts old
    /// items' media to free space (`LibraryIndexService.enforceCacheLimit`),
    /// so by the time encryption is turned on, some pending items' plaintext
    /// media may only exist in iCloud, not locally — `migrateItem` alone
    /// would fail those with `.mediaMissing` even though the bytes are safe,
    /// just not cached.
    ///
    /// Deliberately swallows (and logs) any materialize failure rather than
    /// propagating it: `migrateItem` already has its own well-defined,
    /// crash-safe handling of "media absent" (either the crash-orphan
    /// self-heal in `isAlreadyMigrated`, or a genuine `.mediaMissing` that
    /// safely leaves the item pending for a future retry — no data is ever
    /// lost either way). This step exists purely to give that existing logic
    /// its best shot at finding the bytes locally first; it must never
    /// introduce a new failure mode of its own, since a hard failure here
    /// (e.g. a transient network blip, or a genuinely non-ubiquitous missing
    /// file) would wrongly abort an otherwise-resumable migration.
    ///
    /// Runs synchronously on the caller's thread — `migrateAllMaterializing`
    /// runs entirely on `LibraryEncryptionCoordinator`'s dedicated migration
    /// queue (a plain background thread, never a `Task`), so bridging into
    /// the async `LibraryFileMaterializer` calls needs a semaphore rather
    /// than the continuation-based `runIO` idiom those calls themselves use
    /// (that idiom bridges the other direction: async caller → blocking
    /// queue). The semaphore only ever blocks that dedicated thread, never a
    /// Swift concurrency cooperative-pool thread — exactly the blocking that
    /// pool exists to avoid elsewhere in this app.
    private func materializeIfNeeded(_ url: URL) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            if await LibraryFileMaterializer.isReady(url: url) == false {
                do {
                    try await LibraryFileMaterializer.download(url: url)
                } catch {
                    print("[LibraryEncryptionMigrator] couldn't materialize \(url.lastPathComponent) before migrating: \(error)")
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Forward migration variant of `migrateAll` that materializes each
    /// pending item's plaintext media from iCloud first (see
    /// `materializeIfNeeded`) before handing off to the exact same
    /// `migrateItem`/`migrateAux` calls `migrateAll` uses — same cumulative
    /// `(done, total)` progress across both passes, same stop-on-first-
    /// failure behavior, same crash-safety guarantees. This is the entry
    /// point `LibraryEncryptionCoordinator.enable` uses instead of
    /// `migrateAll`.
    func migrateAllMaterializing(progress: (Int, Int) -> Void) throws {
        let itemIDs = pendingItemIDs()
        let auxNames = pendingAuxNames()
        let total = itemIDs.count + auxNames.count
        var done = 0

        for id in itemIDs {
            let ext = mediaExtension(forItemID: id)
            materializeIfNeeded(itemsDirectory.appendingPathComponent("\(id).\(ext)"))
            try migrateItem(itemID: id, plaintextExtension: ext)
            done += 1
            progress(done, total)
        }

        for name in auxNames {
            try migrateAux(name: name)
            done += 1
            progress(done, total)
        }
    }

    /// Total pending work `migrateAllMaterializing` will report progress
    /// against (items + aux files) — exposed so a caller (the coordinator)
    /// can publish the correct denominator in its very first progress update,
    /// before the migration loop itself has run far enough to report a
    /// `total` via its own `progress` callback.
    func pendingItemsAndAuxCount() -> Int {
        pendingItemIDs().count + pendingAuxNames().count
    }

    // MARK: Reverse — Items (encrypted → plaintext, for disabling encryption)

    /// Encrypted item ids still awaiting reverse migration: every item whose
    /// ciphertext sidecar (`*.m`) is present, identified via the sidecar's
    /// decrypted `{ itemID }` stub (`itemID(forMetadataFile:)`) since the
    /// on-disk filename itself is an opaque token and carries no id.
    func pendingEncryptedItemIDs() -> [Int] {
        encryptedStore.enumerateMetadataFiles().compactMap { encryptedStore.itemID(forMetadataFile: $0) }
    }

    /// Reverse of `migrateItem`: decrypts one item's sidecar + media back to
    /// plaintext `<id>.json` / `<id>.<ext>`, mirroring its crash-safety
    /// pattern exactly. Idempotent: if the ciphertext sidecar is already gone
    /// (a prior run finished it), this is a no-op.
    func decryptItem(itemID: Int) throws {
        guard let sidecar = encryptedStore.readMetadata(itemID: itemID) else { return }   // already decrypted (or never existed)
        guard let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: sidecar) else { return }
        let ext = meta.mediaType.fileExtension
        let sidecarURL = itemsDirectory.appendingPathComponent("\(itemID).json")
        let mediaURL = itemsDirectory.appendingPathComponent("\(itemID).\(ext)")

        guard let media = encryptedStore.readMedia(itemID: itemID, plaintextExtension: ext) else {
            // Ciphertext sidecar present but ciphertext media absent.
            // Forward migration always writes ciphertext media BEFORE
            // ciphertext metadata, so a genuinely incomplete forward write
            // leaves the OPPOSITE shape (media present, metadata absent) —
            // never this one. This shape instead means `LibraryFileStore
            // .removeItem`'s own crash-orphan window: it deletes ciphertext
            // media before ciphertext metadata (mirroring forward's
            // plaintext-delete order, precisely so the surviving file is the
            // one enumeration keys off), so a crash between those two
            // internal deletes leaves exactly this, with the plaintext for
            // this item already fully written+verified by an earlier call.
            // Confirm that before self-healing by removing the leftover
            // ciphertext metadata; otherwise this is a genuine failure.
            if isMetadataOnlyCrashOrphan(sidecarURL: sidecarURL, sidecar: sidecar, mediaURL: mediaURL) {
                encryptedStore.removeItem(itemID: itemID, plaintextExtension: ext)
                return
            }
            throw MigrateError.mediaMissing
        }

        // Crash-orphan self-heal: a prior run already wrote+verified the
        // plaintext for this item and crashed before even calling
        // `removeItem` (both ciphertext files still fully present). Recognize
        // that and clean up the leftover ciphertext instead of re-writing
        // plaintext that's already correct.
        if isAlreadyDecrypted(sidecarURL: sidecarURL, sidecar: sidecar, mediaURL: mediaURL, media: media) {
            encryptedStore.removeItem(itemID: itemID, plaintextExtension: ext)
            return
        }

        try media.write(to: mediaURL, options: .atomic)
        try sidecar.write(to: sidecarURL, options: .atomic)

        // Verify the plaintext just written round-trips: it must match what
        // was just decrypted, AND an independent re-decrypt of the
        // still-present ciphertext (through `verifyStore`, see its doc
        // comment) must agree too, before anything is deleted.
        guard (try? Data(contentsOf: mediaURL)) == media,
              (try? Data(contentsOf: sidecarURL)) == sidecar,
              verifyStore.readMedia(itemID: itemID, plaintextExtension: ext) == media,
              verifyStore.readMetadata(itemID: itemID) == sidecar else {
            throw MigrateError.verifyFailed
        }

        encryptedStore.removeItem(itemID: itemID, plaintextExtension: ext)
    }

    /// True when this item's plaintext already exists on disk and matches
    /// byte-for-byte the just-decrypted ciphertext — the signal that this is
    /// the crash-orphan case (plaintext already written+verified by a prior
    /// run, which then crashed before, or partway through, deleting the
    /// ciphertext) rather than a genuinely un-started item. Mirrors
    /// `isAlreadyMigrated` in the forward direction. Always checked against
    /// the real on-disk plaintext bytes (never `verifyCryptoOverride`, which
    /// only affects `decryptItem`'s own verify-before-delete step).
    private func isAlreadyDecrypted(sidecarURL: URL, sidecar: Data, mediaURL: URL, media: Data) -> Bool {
        (try? Data(contentsOf: sidecarURL)) == sidecar && (try? Data(contentsOf: mediaURL)) == media
    }

    /// True when, despite ciphertext media already being gone, the
    /// ciphertext metadata still present decodes to exactly the on-disk
    /// plaintext sidecar AND a plaintext media file exists at `mediaURL` —
    /// the signal that this is `LibraryFileStore.removeItem`'s crash-orphan
    /// window (media deleted, metadata not yet, with the plaintext already
    /// fully written+verified) rather than a genuinely unwritten media file.
    /// Weaker than `isAlreadyDecrypted` (there's no ciphertext media left to
    /// byte-compare the plaintext media against), but this combination can't
    /// otherwise arise: see the call site's comment for why a genuinely
    /// incomplete forward write can never produce it.
    private func isMetadataOnlyCrashOrphan(sidecarURL: URL, sidecar: Data, mediaURL: URL) -> Bool {
        (try? Data(contentsOf: sidecarURL)) == sidecar && FileManager.default.fileExists(atPath: mediaURL.path)
    }

    // MARK: Reverse — Aux (album files, sort-assistant state)

    /// Reverse of `migrateAux`: decrypts one opaque `.x` aux file back to its
    /// literal plaintext name. Aux files carry no filename hint the way item
    /// sidecars do (`itemID(forMetadataFile:)`'s `{ itemID }` stub) — the
    /// plaintext name is instead recovered by decode-and-classify: content
    /// that decodes as `LibraryAlbumFile` gives its exact `album-<uuid>.json`
    /// name via `LibraryAlbumStore.fileName(for:)`; content that decodes as
    /// `SortAssistantState` is the singleton `sort-assistant-state.json`;
    /// anything else can't be classified and is left encrypted. Same
    /// verify-before-delete and crash-orphan self-heal as `decryptItem`.
    private func decryptAux(at url: URL) throws {
        guard let payload = encryptedStore.readAux(at: url) else { return }   // unreadable, or already gone

        let plaintextName: String
        if let album = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: payload) {
            plaintextName = LibraryAlbumStore.fileName(for: album.id)
        } else if (try? JSONDecoder().decode(SortAssistantState.self, from: payload)) != nil {
            plaintextName = SortAssistantStateStore.fileName
        } else {
            return   // Unrecognized aux payload — can't classify; leave ciphertext in place.
        }

        let plaintextURL = itemsDirectory.appendingPathComponent(plaintextName)

        // Crash-orphan self-heal, mirroring `isAlreadyDecrypted` above.
        if (try? Data(contentsOf: plaintextURL)) == payload {
            encryptedStore.removeAux(name: plaintextName)
            return
        }

        try payload.write(to: plaintextURL, options: .atomic)

        guard (try? Data(contentsOf: plaintextURL)) == payload,
              verifyStore.readAux(at: url) == payload else {
            throw MigrateError.verifyFailed
        }

        encryptedStore.removeAux(name: plaintextName)
    }

    // MARK: Reverse — All

    /// Decrypts every pending item, then every pending aux file, reporting
    /// cumulative `(done, total)` progress across both passes as each
    /// completes — mirrors `migrateAll` exactly, in reverse. Stops
    /// (throwing) on the first failure, leaving whatever hasn't been reached
    /// yet untouched and resumable.
    ///
    /// Then, before returning normally, asserts REAL completeness: neither
    /// `decryptItem` nor `decryptAux` is guaranteed to either fully convert
    /// an item/aux file or throw — each has a legitimate silent-no-op path
    /// (an unclassifiable aux payload; an item whose sidecar decodes as the
    /// tiny stub `pendingEncryptedItemIDs()` uses but fails the full
    /// `LibraryItemMetadata` decode `decryptItem` needs). Looping over a
    /// snapshot of pending work and calling `progress` for each entry would
    /// otherwise let such an item finish the loop "counted done" while its
    /// ciphertext is still sitting on disk untouched. Callers — in
    /// particular the disable-encryption coordinator deciding whether it's
    /// safe to discard the DEK — must be able to trust a non-throwing return
    /// as a hard guarantee that zero ciphertext remains, so re-check both
    /// `pendingEncryptedItemIDs()` and `enumerateAuxFiles()` are empty and
    /// throw `.incomplete` if not. (`migrateAll`, the forward direction,
    /// doesn't have this gap: `migrateItem` never decodes the plaintext
    /// sidecar to decide whether to act — it moves bytes unconditionally —
    /// so it has no analogous silent no-op path to guard against.)
    ///
    /// **`pendingEncryptedItemIDs()` alone is not enough for this recheck,
    /// and never was.** It's `enumerateMetadataFiles().compactMap {
    /// itemID(forMetadataFile:) }` — a `.m` sidecar whose GCM-open or
    /// `{ itemID }` stub-decode fails is silently DROPPED by `compactMap`,
    /// not surfaced as an error. So a present-but-undecodable ciphertext
    /// sidecar (corrupted on disk, for whatever reason) is invisible to
    /// `pendingEncryptedItemIDs().isEmpty` even though its `.m` (and
    /// possibly still-intact `.b`) file is very much still there: the guard
    /// would pass, the disable-encryption coordinator would trust the clean
    /// return and tear down the vault, and that ciphertext would become
    /// permanently unrecoverable the moment the DEK is discarded. The guard
    /// therefore ALSO re-checks the RAW file listing,
    /// `encryptedStore.enumerateMetadataFiles().isEmpty` — pure filename
    /// matching, no decode attempted, so an undecodable sidecar still counts
    /// as "remaining" and correctly forces `.incomplete`. Kept alongside
    /// (not instead of) `pendingEncryptedItemIDs().isEmpty` since that's the
    /// pre-existing guard the "stub decodes, full `LibraryItemMetadata`
    /// decode fails" case was originally written against — both checks are
    /// cheap, and requiring both to be empty is strictly safer than either
    /// alone.
    func decryptAll(progress: (Int, Int) -> Void) throws {
        let itemIDs = pendingEncryptedItemIDs()
        let auxURLs = encryptedStore.enumerateAuxFiles()
        let total = itemIDs.count + auxURLs.count
        var done = 0

        for id in itemIDs {
            try decryptItem(itemID: id)
            done += 1
            progress(done, total)
        }

        for url in auxURLs {
            try decryptAux(at: url)
            done += 1
            progress(done, total)
        }

        guard pendingEncryptedItemIDs().isEmpty,
              encryptedStore.enumerateMetadataFiles().isEmpty,
              encryptedStore.enumerateAuxFiles().isEmpty else {
            throw MigrateError.incomplete
        }
    }

    /// Reverse migration variant of `decryptAll` that materializes each
    /// pending item's/aux file's CIPHERTEXT from iCloud first — the mirror
    /// image of `migrateAllMaterializing`'s forward materialize step, and the
    /// entry point `LibraryEncryptionCoordinator.disable` uses instead of
    /// `decryptAll`.
    ///
    /// Without this, `disable()` could never complete against a large
    /// library whose ENCRYPTED media has been evicted to free space
    /// (`LibraryIndexService.enforceCacheLimit` evicts media, not sidecars —
    /// but a device that received an already-encrypted item synced in from
    /// elsewhere, without ever downloading its media locally, hits the same
    /// "not locally present" situation): `decryptItem` would throw
    /// `.mediaMissing` every time, and `decryptAll`'s hard completeness
    /// guarantee (see its doc comment) would then correctly refuse to let
    /// `disable()` tear down the vault — data-safe, but permanently stuck.
    ///
    /// Materializes BEFORE any decode is attempted, not just before each
    /// `decryptItem` call, and this ordering matters: unlike
    /// `migrateAllMaterializing`'s `pendingItemIDs()` (which only parses
    /// `<id>.json` FILENAMES — no read required), `pendingEncryptedItemIDs()`
    /// must decrypt+decode each opaque `.m` sidecar's tiny `{ itemID }` stub
    /// just to learn which items exist at all (the on-disk filename is an
    /// opaque token carrying no id). If a sidecar were left un-materialized,
    /// `itemID(forMetadataFile:)` would fail to read it and
    /// `pendingEncryptedItemIDs()` would silently drop that item from
    /// enumeration entirely — not merely fail to decrypt it, but never even
    /// attempt it, and never surface it via `.incomplete` either, since the
    /// post-loop recheck uses the same enumeration. So every opaque metadata
    /// (`.m`) and aux (`.x`) file is materialized up front, by directory
    /// listing alone (`enumerateMetadataFiles`/`enumerateAuxFiles`, which
    /// only filter filenames — no decode), before `pendingEncryptedItemIDs()`
    /// is ever called. Each item's media file is then materialized
    /// individually right before its `decryptItem` call.
    func decryptAllMaterializing(progress: (Int, Int) -> Void) throws {
        for url in encryptedStore.enumerateMetadataFiles() {
            materializeIfNeeded(url)
        }
        let auxURLs = encryptedStore.enumerateAuxFiles()
        for url in auxURLs {
            materializeIfNeeded(url)
        }

        let itemIDs = pendingEncryptedItemIDs()
        let total = itemIDs.count + auxURLs.count
        var done = 0

        for id in itemIDs {
            // The plaintext-extension argument is ignored under encryption —
            // the media role's on-disk token doesn't depend on it (see
            // `LibraryFileStore.mediaURL`) — so any placeholder value here
            // still resolves the correct opaque media URL.
            materializeIfNeeded(encryptedStore.mediaURL(itemID: id, plaintextExtension: ""))
            try decryptItem(itemID: id)
            done += 1
            progress(done, total)
        }

        for url in auxURLs {
            try decryptAux(at: url)
            done += 1
            progress(done, total)
        }

        // Same hard completeness recheck as `decryptAll` (see its doc comment
        // for why `pendingEncryptedItemIDs()` alone can silently miss a
        // present-but-undecodable `.m` sidecar): both the decoded-ids view
        // AND the raw file listing must be empty before the caller may treat
        // zero ciphertext as remaining.
        guard pendingEncryptedItemIDs().isEmpty,
              encryptedStore.enumerateMetadataFiles().isEmpty,
              encryptedStore.enumerateAuxFiles().isEmpty else {
            throw MigrateError.incomplete
        }
    }

    /// Total pending work `decryptAllMaterializing` will report progress
    /// against (encrypted items + aux files) — mirrors
    /// `pendingItemsAndAuxCount()`, exposed so the coordinator can publish
    /// the correct denominator in its very first `.decrypting` update.
    func pendingEncryptedItemsAndAuxCount() -> Int {
        pendingEncryptedItemIDs().count + encryptedStore.enumerateAuxFiles().count
    }
}
