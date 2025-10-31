import SwiftUI

enum MediaLoadingState: Equatable {
    case idle
    case loading
    case loaded(MediaContent)
    case failed(Error)

    static func == (lhs: MediaLoadingState, rhs: MediaLoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case (.loaded(let content1), .loaded(let content2)):
            return content1 == content2
        case (.failed(let err1), .failed(let err2)):
            return (err1 as NSError) == (err2 as NSError)
        default:
            return false
        }
    }
}
