import SwiftUI

struct FeedItemStats: View {
    let likeCount: Int
    let heartCount: Int
    let laughCount: Int
    let cryCount: Int
    let commentCount: Int
    let dislikeCount: Int

    var body: some View {
        HStack(spacing: 16) {
            if likeCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(FormatUtilities.formatCount(likeCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if heartCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text("\(FormatUtilities.formatCount(heartCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if laughCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "face.smiling")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(FormatUtilities.formatCount(laughCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if cryCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "face.dashed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(FormatUtilities.formatCount(cryCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if commentCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "message")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(FormatUtilities.formatCount(commentCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if dislikeCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "hand.thumbsdown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(FormatUtilities.formatCount(dislikeCount))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}