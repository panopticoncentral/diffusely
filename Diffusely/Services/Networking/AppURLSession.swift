import Foundation

extension URLSession {
    /// Shared session with bounded timeouts and a durable on-disk image cache
    /// for all app networking.
    ///
    /// `URLSession.shared` defaults to a `timeoutIntervalForResource` of 7 days,
    /// so a stalled connection can hang a request far longer than any retry or
    /// loading-state logic expects. Here:
    ///   - `timeoutIntervalForRequest` (20s) is reset whenever new data arrives,
    ///     so it acts as a "no progress" guard that catches a true stall fast.
    ///   - `timeoutIntervalForResource` (300s) caps total request time, generous
    ///     enough for a large full-res library download but far short of 7 days.
    ///
    /// A disk-backed `URLCache` (in Application Support, so the OS does not purge
    /// it under storage pressure) plus `ImageCacheForcingDelegate` give immutable
    /// CDN thumbnails true zero-network reuse across launches. See
    /// `ImageCacheForcingDelegate` for why force-caching is required.
    static let civitai: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        config.urlCache = makeImageURLCache()
        config.requestCachePolicy = .useProtocolCachePolicy
        // `ImageCacheForcingDelegate` implements only `willCacheResponse`; all other
        // delegate callbacks (redirects, auth challenges, server-trust) are unimplemented
        // and fall back to `URLSession`'s default handling, so attaching it does not change
        // non-caching behavior.
        return URLSession(
            configuration: config,
            delegate: ImageCacheForcingDelegate(),
            delegateQueue: nil
        )
    }()

    /// The on-disk location for the image `URLCache`. Application Support (not
    /// Caches) so the OS will not purge it under storage pressure — durability
    /// across launches is the point. Mirrors LibraryThumbnailStore's convention.
    /// Returns nil only if Application Support is unavailable, in which case the
    /// caller falls back to URLCache's default location.
    /// Not private so it can be verified by tests.
    static func imageCacheDirectory() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else {
            return nil
        }
        return appSupport.appendingPathComponent("NetworkImageCache", isDirectory: true)
    }

    private static func makeImageURLCache() -> URLCache {
        let memoryCapacity = 50 * 1024 * 1024     // 50 MB
        let diskCapacity = 500 * 1024 * 1024      // 500 MB
        return URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            directory: imageCacheDirectory()
        )
    }
}
