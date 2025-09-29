import Foundation

enum Timeframe: String, CaseIterable, Identifiable, Equatable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case allTime = "AllTime"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .day:
            return "Today"
        case .week:
            return "This Week"
        case .month:
            return "This Month"
        case .year:
            return "This Year"
        case .allTime:
            return "All Time"
        }
    }
    
    var shortName: String {
        switch self {
        case .day:
            return "Day"
        case .week:
            return "Week"
        case .month:
            return "Month"
        case .year:
            return "Year"
        case .allTime:
            return "All"
        }
    }
    
    var description: String {
        switch self {
        case .day:
            return "From today"
        case .week:
            return "From this week"
        case .month:
            return "From this month"
        case .year:
            return "From this year"
        case .allTime:
            return "All ever"
        }
    }
}
