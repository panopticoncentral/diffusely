import Foundation

enum FeedSort: String, CaseIterable, Identifiable, Equatable {
    case mostReactions = "Most Reactions"
    case mostComments = "Most Comments"
    case mostCollected = "Most Collected"
    case newest = "Newest"
    case oldest = "Oldest"
    case random = "Random"
    
    var id: String { rawValue }
    
    var displayName: String {
        return rawValue
    }
    
    var icon: String {
        switch self {
        case .mostReactions:
            return "heart.fill"
        case .mostComments:
            return "message.fill"
        case .mostCollected:
            return "star.fill"
        case .newest:
            return "clock.fill"
        case .oldest:
            return "calendar"
        case .random:
            return "shuffle"
        }
    }
}
