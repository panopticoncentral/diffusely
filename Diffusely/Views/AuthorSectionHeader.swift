import SwiftUI

struct AuthorSectionHeader: View {
    let author: CivitaiUser
    let itemCount: Int
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Author avatar
                if let imageURL = author.image, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            placeholderAvatar
                        case .empty:
                            ProgressView()
                                .frame(width: 40, height: 40)
                        @unknown default:
                            placeholderAvatar
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    placeholderAvatar
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(author.username ?? "Unknown Artist")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("\(itemCount) \(itemCount == 1 ? "item" : "items")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: "person.fill")
                    .foregroundColor(.gray)
            )
    }
}
