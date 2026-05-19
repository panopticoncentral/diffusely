import Foundation

/// Outcome of inspecting a sync error.
enum SyncErrorClassification: Equatable {
    case transient    // retry with backoff
    case fatal        // stop the run, surface as lastError
    case cancellation // task was cancelled — not an error
}

/// Classifies an error thrown by a collection page fetch.
///
/// Known limitation: `fetchImagesPage`/`fetchPostsPage` don't inspect HTTP
/// status, so a 429/5xx that returns a body surfaces as a `DecodingError`
/// and is classified `.fatal`. HTTP-status-aware classification is out of
/// scope (see spec).
func classifySyncError(_ error: Error) -> SyncErrorClassification {
    if error is CancellationError { return .cancellation }
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
