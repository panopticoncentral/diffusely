import Foundation

enum ContentRating: Int, CaseIterable, Identifiable {
    case g = 1
    case pg = 2
    case pg13 = 4
    case r = 8
    case x = 16
    case xxx = 32
    
    var id: Int { rawValue }
    
    var displayName: String {
        switch self {
        case .g:
            return "G"
        case .pg:
            return "PG"
        case .pg13:
            return "PG-13"
        case .r:
            return "R"
        case .x:
            return "X"
        case .xxx:
            return "XXX"
        }
    }
    
    var description: String {
        switch self {
        case .g:
            return "General Audiences"
        case .pg:
            return "Parental Guidance"
        case .pg13:
            return "Parents Strongly Cautioned"
        case .r:
            return "Restricted"
        case .x:
            return "Adults Only"
        case .xxx:
            return "Explicit Content"
        }
    }
    
    // Calculate the browsing level value (sum of all ratings up to and including this one)
    var browsingLevelValue: Int {
        let allRatings = ContentRating.allCases
        let currentIndex = allRatings.firstIndex(of: self) ?? 0
        return allRatings[0...currentIndex].reduce(0) { $0 + $1.rawValue }
    }
}