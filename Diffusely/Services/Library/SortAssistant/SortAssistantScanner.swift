import Foundation

/// One-shot container scan for the Sort Assistant: every readable item sidecar
/// plus every album file. Mirrors `FileLibraryBackfillSidecarStore`'s
/// detached-task pattern so the directory walk and JSON decodes never run on
/// the caller's actor. Dataless iCloud placeholders are skipped — their
/// prompts aren't readable without a blocking FileProvider download; they'll
/// be picked up by a later run once materialized.
struct SortAssistantScanner {
    let itemsDirectory: URL

    struct ScanResult: Sendable {
        var items: [LibraryItemMetadata] = []
        var albums: [LibraryAlbumFile] = []
    }

    func scan() async -> ScanResult {
        let directory = itemsDirectory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            // Prefetch ubiquitous-status keys so the per-file
            // `isDatalessPlaceholder` checks below read the enumeration cache
            // instead of XPCing to fileproviderd once per sidecar.
            let urls = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: LibraryIndexService.scanPrefetchKeys)) ?? []
            var result = ScanResult()
            for url in urls where url.pathExtension == "json" {
                guard !LibraryIndexService.isDatalessPlaceholder(url) else { continue }
                let name = url.lastPathComponent
                if LibraryAlbumStore.albumID(fromFileName: name) != nil {
                    if let data = try? Data(contentsOf: url),
                       let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data) {
                        result.albums.append(file)
                    }
                    continue
                }
                guard name != SortAssistantStateStore.fileName else { continue }
                if let data = try? Data(contentsOf: url),
                   let meta = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data) {
                    result.items.append(meta)
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
