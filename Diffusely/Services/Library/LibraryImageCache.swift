import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Process-wide in-memory cache of decoded, downsampled library thumbnails.
/// Fills the gap left by per-view `LibraryMediaLoader` instances: a cell that
/// scrolls out of the `LazyVStack` is torn down along with its loader and the
/// `PlatformImage` it held, so without this a re-appear re-reads and re-decodes
/// the file from disk every time. Parallel to `MediaCacheService`'s in-memory
/// dictionary, but for the local-library (file-backed) path only.
///
/// `NSCache` is thread-safe and self-purges under memory pressure, so this is a
/// plain `final class` with no actor isolation — it's read from the main actor
/// (the fast-path check in `load()`) and written from detached decode tasks.
final class LibraryImageCache: @unchecked Sendable {
    static let shared = LibraryImageCache()

    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        // Decoded-pixel ceiling; NSCache also drops everything on a UIKit
        // memory warning automatically, matching MediaCacheService's intent.
        cache.totalCostLimit = 96 * 1024 * 1024  // ~96 MB
    }

    /// Folds the requested dimension into the key so the detail view's larger
    /// decode and the grid's 600px thumbnail don't evict or mis-serve each other.
    private func key(fileName: String, maxDimension: CGFloat) -> NSString {
        "\(fileName)@\(Int(maxDimension))" as NSString
    }

    func image(fileName: String, maxDimension: CGFloat) -> PlatformImage? {
        cache.object(forKey: key(fileName: fileName, maxDimension: maxDimension))
    }

    func insert(_ image: PlatformImage, fileName: String, maxDimension: CGFloat) {
        cache.setObject(
            image,
            forKey: key(fileName: fileName, maxDimension: maxDimension),
            cost: image.decodedByteCost
        )
    }
}

private extension PlatformImage {
    /// Rough decoded footprint (w × h × 4 bytes) for NSCache cost accounting.
    var decodedByteCost: Int {
        #if canImport(UIKit)
        let px = size.width * scale * size.height * scale
        #else
        let px = size.width * size.height
        #endif
        return Int(px) * 4
    }
}
