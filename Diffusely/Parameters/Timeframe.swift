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
}
