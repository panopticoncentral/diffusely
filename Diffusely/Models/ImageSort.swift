//
//  ImageSort.swift
//  Diffusely
//
//  Created by Claude on 8/28/25.
//

import Foundation

enum ImageSort: String, CaseIterable, Identifiable {
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
    
    var shortName: String {
        switch self {
        case .mostReactions:
            return "Reactions"
        case .mostComments:
            return "Comments"
        case .mostCollected:
            return "Collected"
        case .newest:
            return "Newest"
        case .oldest:
            return "Oldest"
        case .random:
            return "Random"
        }
    }
    
    var description: String {
        switch self {
        case .mostReactions:
            return "Images with the most likes and hearts"
        case .mostComments:
            return "Images with the most comments"
        case .mostCollected:
            return "Images saved to the most collections"
        case .newest:
            return "Most recently published images"
        case .oldest:
            return "Oldest published images"
        case .random:
            return "Random selection of images"
        }
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