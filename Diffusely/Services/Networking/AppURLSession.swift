import Foundation

extension URLSession {
    /// Shared session with bounded timeouts for all app networking.
    ///
    /// `URLSession.shared` defaults to a `timeoutIntervalForResource` of 7 days,
    /// so a stalled connection can hang a request far longer than any retry or
    /// loading-state logic expects. Here:
    ///   - `timeoutIntervalForRequest` (20s) is reset whenever new data arrives,
    ///     so it acts as a "no progress" guard that catches a true stall fast.
    ///   - `timeoutIntervalForResource` (300s) caps total request time, generous
    ///     enough for a large full-res library download but far short of 7 days.
    static let civitai: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
}
