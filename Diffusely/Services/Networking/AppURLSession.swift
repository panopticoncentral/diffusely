import Foundation

extension URLSession {
    /// Shared session for the Civitai JSON API (and, until the Library migration,
    /// the Library's CDN thumbnail fallback). Image loading uses Nuke's own
    /// pipeline/session.
    ///
    /// `URLSession.shared` defaults to a 7-day `timeoutIntervalForResource`, so a
    /// stalled connection can hang far longer than any retry/loading logic expects:
    ///   - `timeoutIntervalForRequest` (20s) is a "no progress" guard.
    ///   - `timeoutIntervalForResource` (300s) caps total request time.
    static let civitai: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
}
