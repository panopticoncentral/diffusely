import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Durable, per-device, on-disk cache of library grid thumbnails (`<id>.jpg`).
/// Lives in Application Support (not Caches, which the OS may purge under
/// storage pressure; not iCloud, which would evict and sync them). Tiny —
/// ~100 MB for a full library — so the app never evicts it. File I/O is
/// thread-safe to call off the main actor.
final class LibraryThumbnailStore: @unchecked Sendable {
    static let shared = LibraryThumbnailStore()

    /// Pixel size grid thumbnails are generated and stored at. Requests at or
    /// below this size are served from the cache; larger requests (detail view)
    /// bypass it and load the full original.
    static let gridThumbnailDimension: CGFloat = 600

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = try! FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            self.directory = appSupport.appendingPathComponent("LibraryThumbnails", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(itemID: Int) -> URL {
        directory.appendingPathComponent("\(itemID).jpg", isDirectory: false)
    }

    func thumbnail(itemID: Int) -> PlatformImage? {
        guard let data = try? Data(contentsOf: fileURL(itemID: itemID)) else { return nil }
        return PlatformImage(data: data)   // nil if the bytes aren't a valid image
    }

    func store(_ image: PlatformImage, itemID: Int) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: fileURL(itemID: itemID), options: .atomic)
    }

    func remove(itemID: Int) {
        try? FileManager.default.removeItem(at: fileURL(itemID: itemID))
    }

    func removeAll() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Test seam: write arbitrary bytes to an item's slot to simulate corruption.
    func writeRawForTesting(_ data: Data, itemID: Int) throws {
        try data.write(to: fileURL(itemID: itemID), options: .atomic)
    }
}
