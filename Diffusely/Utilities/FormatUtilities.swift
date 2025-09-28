import Foundation

struct FormatUtilities {
    static func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let now = Date()
            let timeInterval = now.timeIntervalSince(date)

            if timeInterval < 60 {
                return "now"
            } else if timeInterval < 3600 {
                let minutes = Int(timeInterval / 60)
                return "\(minutes)m"
            } else if timeInterval < 86400 {
                let hours = Int(timeInterval / 3600)
                return "\(hours)h"
            } else if timeInterval < 604800 {
                let days = Int(timeInterval / 86400)
                return "\(days)d"
            } else {
                let weeks = Int(timeInterval / 604800)
                return "\(weeks)w"
            }
        }
        return ""
    }

    static func formatCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1000000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        } else {
            return "\(count)"
        }
    }
}