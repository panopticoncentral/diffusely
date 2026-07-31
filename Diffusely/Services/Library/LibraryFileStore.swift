import Foundation

/// The single indirection for all personal-Library container I/O. With a
/// `crypto`, contents are AES-GCM sealed and names are opaque tokens; without
/// one, it is a pure passthrough to today's `<id>.json` / `<id>.<ext>` layout.
/// Synchronous, file-coordinated I/O — call from the Library's dedicated I/O
/// queue, never the cooperative pool, matching `LibraryFileWriter`.
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

    /// Best-effort coordinated delete of both files for an item, matching
    /// `LibraryStore.deleteFiles` (missing files are silently skipped).
    /// Deletes media BEFORE metadata deliberately: callers that scan for
    /// pending work by metadata presence (`enumerateMetadataFiles()`, and
    /// `LibraryEncryptionMigrator.pendingEncryptedItemIDs()` built on it) key
    /// off the metadata file, so if this function is interrupted between its
    /// two deletes, leaving metadata deleted first would make the leftover
    /// media file invisible to any future rescan forever. Deleting media
    /// first instead means an interruption leaves metadata as the survivor —
    /// still found by those scans, so a caller like the migrator's
    /// `decryptItem` gets a chance to notice and self-heal the leftover
    /// metadata on its next run, rather than the orphan going permanently
    /// untracked.
    func removeItem(itemID: Int, plaintextExtension ext: String) {
        let coordinator = NSFileCoordinator()
        for url in [mediaURL(itemID: itemID, plaintextExtension: ext), metadataURL(itemID: itemID)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var err: NSError?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    // MARK: Aux (non-item container files: album files, sort-assistant state)

    /// URL for a logical non-item container file, identified by a stable
    /// `name` (e.g. "album-<uuid>" or "sort-assistant-state") rather than an
    /// itemID. Encrypted: opaque `<token>.x` name. Plaintext: the literal
    /// name as given (callers pass the full legacy filename themselves, e.g.
    /// "album-<uuid>.json").
    func auxURL(name: String) -> URL {
        if let crypto {
            return itemsDirectory.appendingPathComponent(crypto.fileName(auxName: name))
        }
        return itemsDirectory.appendingPathComponent(name)
    }

    func writeAux(_ data: Data, name: String) throws {
        try write(payload: data, to: auxURL(name: name), token: crypto?.fileToken(auxName: name))
    }

    func readAux(name: String) -> Data? {
        read(url: auxURL(name: name), token: crypto?.fileToken(auxName: name))
    }

    /// Best-effort coordinated delete of a logical aux file (album file,
    /// sort-assistant state), located the same way `writeAux`/`readAux`
    /// locate it — opaque `<token>.x` when encrypted, the literal `name` when
    /// plaintext. Missing files are silently skipped, matching `removeItem`'s
    /// semantics.
    func removeAux(name: String) {
        let url = auxURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSFileCoordinator()
        var err: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// Reads and decrypts an aux file located by its on-disk URL (as returned
    /// by `enumerateAuxFiles()`), recovering the token directly from the
    /// filename stem rather than re-deriving it from a logical name — mirrors
    /// `itemID(forMetadataFile:)`'s approach for metadata files. This is how a
    /// caller that only has an unlabeled `.x` URL (album files and, once
    /// routed through the store, sort-assistant state share this namespace
    /// with no filename hint) can open it without already knowing which
    /// logical name produced it. Encrypted only; plaintext aux files are read
    /// by their literal name via `readAux(name:)` instead.
    func readAux(at url: URL) -> Data? {
        guard isEncrypted else { return nil }
        let token = url.deletingPathExtension().lastPathComponent
        return read(url: url, token: token)
    }

    /// Encrypted: every opaque `*.x` file in the directory (album files and
    /// sort-assistant state share this namespace; disambiguating between
    /// them is the caller's job — decode-and-classify by content via
    /// `readAux(at:)`). Plaintext: always empty — plaintext mode's callers
    /// keep enumerating by their existing literal name/prefix convention
    /// (e.g. "album-*.json") directly, unchanged by this task.
    func enumerateAuxFiles() -> [URL] {
        guard isEncrypted else { return [] }
        let all = (try? FileManager.default.contentsOfDirectory(
            at: itemsDirectory, includingPropertiesForKeys: Self.enumerationPrefetchKeys)) ?? []
        return all.filter { isAuxFileName($0.lastPathComponent) }
    }

    // MARK: Enumeration

    /// Resource keys prefetched during directory enumeration so a caller that
    /// immediately checks iCloud placeholder status on the returned URLs
    /// (e.g. `LibraryIndexService`'s reconcile scan) gets it served from the
    /// enumerated URL objects' caches instead of a blocking per-file XPC
    /// round-trip to fileproviderd. Mirrors `LibraryIndexService.scanPrefetchKeys`.
    private static let enumerationPrefetchKeys: [URLResourceKey] = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    /// True when `name` matches this store's on-disk metadata-sidecar naming
    /// convention (`*.m` encrypted, `*.json` plaintext). Exposed (not just
    /// baked into `enumerateMetadataFiles()`) so a caller that already holds
    /// a directory listing — e.g. a scan that also needs the listing for
    /// other purposes — can classify names against it without a second
    /// `contentsOfDirectory` walk.
    func isMetadataFileName(_ name: String) -> Bool {
        name.hasSuffix(isEncrypted ? ".m" : ".json")
    }

    /// True when `name` matches this store's opaque aux-file naming
    /// convention (`*.x`, encrypted only — plaintext aux files use their own
    /// literal name and are never classified this way).
    func isAuxFileName(_ name: String) -> Bool {
        isEncrypted && name.hasSuffix(".x")
    }

    func enumerateMetadataFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: itemsDirectory, includingPropertiesForKeys: Self.enumerationPrefetchKeys)) ?? []
        return all.filter { isMetadataFileName($0.lastPathComponent) }
    }

    /// Encrypted: decrypts the sidecar and decodes an `{ itemID }` stub (the
    /// filename is an opaque token and carries no id). Plaintext: parses the
    /// `<id>.json` filename stem directly.
    func itemID(forMetadataFile url: URL) -> Int? {
        if isEncrypted {
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
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        let bytes: Data
        if let token, let crypto { bytes = try crypto.seal(payload, fileToken: token) } else { bytes = payload }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do { try bytes.write(to: destination, options: .atomic) } catch { thrown = error }
        }
        if let coordinationError { throw coordinationError }
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

// MARK: - Async bytes reads (off the cooperative pool)

extension LibraryFileStore {
    /// Dedicated queue for `readMediaAsync`/`readMetadataAsync` below. Every
    /// other Library consumer of blocking, coordinated + (when encrypted)
    /// AES-GCM I/O already has its own private dedicated queue reached via a
    /// `withCheckedContinuation` bridge (`LibraryImageRequest.ioQueue`,
    /// `LibraryMediaLoader.decryptQueue`, `LibraryTempMedia.decryptQueue`) —
    /// this is the same idiom, homed on the store itself so `async` call
    /// sites that only need bytes (no temp file) get one without inventing a
    /// fresh queue per caller. Concurrent: these are independent reads with
    /// no shared mutable state, matching the sibling queues' rationale. See
    /// the "grey-spinner cooperative-pool-starvation" recurring bug class.
    private static let asyncReadQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.fileStoreAsyncRead",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Awaitable `readMedia`, off the cooperative pool: the coordinated read
    /// (can block on an iCloud download) plus, when encrypted, the AES-GCM
    /// decrypt both run on `asyncReadQueue`. Use from `async` call sites that
    /// need decrypted bytes in memory with no temp file involved (metadata
    /// readers, pasteboard/drag providers) — for a real file URL, use
    /// `LibraryTempMedia.materialize` instead. Behaves identically to calling
    /// `readMedia` directly for both plaintext and encrypted stores; only the
    /// executor changes.
    func readMediaAsync(itemID: Int, plaintextExtension ext: String) async -> Data? {
        await withCheckedContinuation { continuation in
            Self.asyncReadQueue.async {
                continuation.resume(returning: readMedia(itemID: itemID, plaintextExtension: ext))
            }
        }
    }

    /// Awaitable `readMetadata`, off the cooperative pool — see
    /// `readMediaAsync` above for the rationale and queue.
    func readMetadataAsync(itemID: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            Self.asyncReadQueue.async {
                continuation.resume(returning: readMetadata(itemID: itemID))
            }
        }
    }
}
