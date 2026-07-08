import SwiftUI

struct FeedItemStats: View {
    private func formatCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1000000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        } else {
            return "\(count)"
        }
    }

    let likeCount: Int
    let heartCount: Int
    let laughCount: Int
    let cryCount: Int
    let commentCount: Int
    let dislikeCount: Int

    var body: some View {
        HStack(spacing: 16) {
            stat(icon: "hand.thumbsup.fill", count: likeCount, color: .secondary, label: "likes")
            stat(icon: "heart.fill", count: heartCount, color: .red, label: "hearts")
            stat(icon: "face.smiling", count: laughCount, color: .secondary, label: "laughs")
            stat(icon: "face.dashed", count: cryCount, color: .secondary, label: "cries")
            stat(icon: "message", count: commentCount, color: .secondary, label: "comments")
            stat(icon: "hand.thumbsdown", count: dislikeCount, color: .secondary, label: "dislikes")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    /// A single icon + count pair, hidden when the count is zero. Grouped as one
    /// accessibility element with a spelled-out label so VoiceOver reads
    /// "1,204 likes" instead of "hand thumbs up fill, 1.2K".
    @ViewBuilder
    private func stat(icon: String, count: Int, color: Color, label: String) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(formatCount(count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(label)")
        }
    }
}