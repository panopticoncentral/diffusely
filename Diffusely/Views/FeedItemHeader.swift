import SwiftUI

struct FeedItemHeader: View {
    let username: String?
    let title: String?

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundColor(.gray)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(username ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if let title = title, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}