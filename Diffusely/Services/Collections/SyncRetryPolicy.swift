import Foundation

/// Outcome of inspecting a sync error.
enum SyncErrorClassification: Equatable {
    case transient    // retry with backoff
    case fatal        // stop the run, surface as lastError
    case cancellation // task was cancelled — not an error
}

/// Classifies an error thrown by a collection page fetch.
///
/// `fetchImagesPage`/`fetchPostsPage` validate HTTP status and throw
/// `HTTPStatusError`, so rate-limiting (429), request timeout (408), and
/// server errors (5xx) are treated as transient and retried with backoff.
/// Other 4xx codes are client errors that won't fix themselves, so they're
/// fatal.
func classifySyncError(_ error: Error) -> SyncErrorClassification {
    if error is CancellationError { return .cancellation }
    if let httpError = error as? HTTPStatusError {
        switch httpError.statusCode {
        case 408, 429, 500...599:
            return .transient
        default:
            return .fatal
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return .transient
        default:
            return .fatal
        }
    }
    return .fatal
}

/// Backoff delay in seconds for a 1-based retry attempt.
/// Schedule: 5s, 15s, 45s, then capped at 60s indefinitely.
func syncRetryDelay(forAttempt attempt: Int) -> Double {
    switch attempt {
    case ..<2:  return 5   // attempt 0 (defensive) and 1
    case 2:     return 15
    case 3:     return 45
    default:    return 60
    }
}
