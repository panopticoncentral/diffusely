import Foundation

extension URLSession {
    /// Shared session for the Civitai tRPC JSON API. Image loading no longer uses
    /// this session: the feed goes through Nuke's pipeline (`AppImagePipeline`),
    /// and the Library's CDN thumbnail fallback uses its own dedicated session in
    /// `LibraryImageRequest`.
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

    /// Session for OpenRouter chat completions (Sort Assistant). LLM calls run
    /// longer than tRPC fetches, so the request timeout is looser than `.civitai`,
    /// but the resource timeout still bounds a stalled connection (the `.shared`
    /// default is 7 days).
    static let openRouter: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()
}
