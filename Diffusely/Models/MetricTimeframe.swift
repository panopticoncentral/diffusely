//
//  MetricTimeframe.swift
//  Diffusely
//
//  Created by Claude on 8/28/25.
//

import Foundation

enum MetricTimeframe: String, CaseIterable, Identifiable {
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
            return "Images from today"
        case .week:
            return "Images from this week"
        case .month:
            return "Images from this month"
        case .year:
            return "Images from this year"
        case .allTime:
            return "All images ever"
        }
    }
}