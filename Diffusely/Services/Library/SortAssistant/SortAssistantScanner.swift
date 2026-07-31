import Foundation

/// One-shot container scan for the Sort Assistant: every readable item sidecar
/// plus every album file. Mirrors `FileLibraryBackfillSidecarStore`'s
/// detached-task pattern so the directory walk and JSON decodes never run on
/// the caller's actor. Dataless iCloud placeholders are skipped — their
/// prompts aren't readable without a blocking FileProvider download; they'll
/// be picked up by a later run once materialized.
struct SortAssistantScanner {
    let itemsDirectory: URL
    /// Resolves the vault's current lock state and (when unlocked) its
    /// crypto. Defaults to the process-wide `LibraryVaultProvider.shared`
    /// singleton (same source `LibraryIndexService.reconcile` and
    /// `FileLibraryBackfillSidecarStore` read), so production call sites need
    /// no change. Overridable so tests can drive `.locked` without touching
    /// the shared singleton — mirrors the seam on `FileLibraryBackfillSidecarStore`.
    var resolveVaultContext: @Sendable () async -> (state: LibraryVault.State, crypto: LibraryFileCrypto?) = {
        let ctx = await LibraryVaultProvider.shared.reconcileContext()
        return (ctx.state, ctx.store.crypto)
    }

    struct ScanResult: Sendable {
        var items: [LibraryItemMetadata] = []
        var albums: [LibraryAlbumFile] = []
    }

    /// Scans the container through the vault-aware store — encrypted when
    /// unlocked, plaintext when never configured. A configured-but-locked
    /// vault has no DEK, so this returns an empty result rather than
    /// scanning: a passthrough store built for a container that is actually
    /// encrypted would find zero readable `*.m`/`*.x` files and silently
    /// report nothing to sort — the same hazard
    /// `LibraryIndexService.reconcile` guards its own scan against.
    func scan() async -> ScanResult {
        let directory = itemsDirectory
        let vault = await resolveVaultContext()
        guard vault.state != .locked else { return ScanResult() }
        let crypto = vault.crypto
        return await Task.detached(priority: .utility) {
            let store = LibraryFileStore(itemsDirectory: directory, crypto: crypto)
            let fm = FileManager.default

            // One directory listing for the whole scan — mirrors
            // `LibraryIndexService.scanContainer(store:)`: filtering a single
            // prefetched listing (rather than calling `enumerateMetadataFiles()`
            // and `enumerateAuxFiles()`, each of which does its own
            // `contentsOfDirectory`) keeps the per-file `isDatalessPlaceholder`
            // checks below served from this call's prefetched resourceValues
            // cache instead of a second blocking XPC round-trip.
            let contents = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: LibraryIndexService.scanPrefetchKeys)) ?? []

            var result = ScanResult()

            let sidecarURLs = contents.filter { store.isMetadataFileName($0.lastPathComponent) }
            for url in sidecarURLs {
                guard !LibraryIndexService.isDatalessPlaceholder(url) else { continue }
                let name = url.lastPathComponent

                // Plaintext album file: the literal `album-{uuid}.json` name
                // also matches `isMetadataFileName`'s `.json` suffix check, so
                // it must be classified and decoded as an album, never
                // attempted as an item sidecar. No-op in encrypted mode (an
                // opaque `.m` token can't match this prefix/suffix); encrypted
                // album rows come from the aux pass below instead.
                if LibraryAlbumStore.albumID(fromFileName: name) != nil {
                    if let data = try? Data(contentsOf: url),
                       let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data) {
                        result.albums.append(file)
                    }
                    continue
                }

                // Item sidecar. `store.itemID(forMetadataFile:)` returns nil
                // for a plaintext filename stem that isn't an integer — which
                // is exactly how `sort-assistant-state.json` (and any other
                // stray `*.json`) is excluded here, without checking its
                // literal name: mirrors how the encrypted aux pass below
                // excludes the state file by content (decode-as-album
                // failing), not by name.
                guard
                    let id = store.itemID(forMetadataFile: url),
                    let data = store.readMetadata(itemID: id),
                    let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
                else { continue }
                result.items.append(meta)
            }

            // Encrypted album rows: album files and the sort-assistant state
            // file share the opaque `.x` aux namespace with no filename hint,
            // so classify by attempting to decode each as a `LibraryAlbumFile`
            // — content that doesn't decode that way (the state file) is
            // skipped, not an error. Mirrors
            // `LibraryIndexService.scanContainer(store:)`'s aux pass exactly.
            if store.isEncrypted {
                let auxURLs = contents.filter { store.isAuxFileName($0.lastPathComponent) }
                for url in auxURLs {
                    guard !LibraryIndexService.isDatalessPlaceholder(url) else { continue }
                    guard
                        let data = store.readAux(at: url),
                        let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data)
                    else { continue }
                    result.albums.append(file)
                }
            }

            // Directory enumeration order is arbitrary; sort so candidate
            // batching is deterministic (stable batches across runs and in tests).
            result.items.sort { $0.itemID < $1.itemID }
            result.albums.sort { $0.createdAt < $1.createdAt }
            return result
        }.value
    }
}
