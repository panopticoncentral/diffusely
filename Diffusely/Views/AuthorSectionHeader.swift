import SwiftUI

struct AuthorSectionHeader: View {
    let author: CivitaiUser
    let itemCount: Int
    let isExpanded: Bool
    /// Tapping the author identity (avatar + name) drills into their content.
    /// When nil (e.g. the local Library, whose authors have no real Civitai
    /// user), the identity area falls back to toggling collapse.
    var onSelectAuthor: (() -> Void)? = nil
    /// Tapping the trailing disclosure chevron collapses/expands the section.
    let onToggleCollapse: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Author identity: navigates to the author's content. The trailing
            // chevron.right mirrors the app's existing "tap to view author"
            // affordance (see ImageDetailView).
            Button(action: onSelectAuthor ?? onToggleCollapse) {
                HStack(spacing: 12) {
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

                    if onSelectAuthor != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            // Disclosure control: collapses/expands the section. Generous
            // padding keeps it a comfortable tap target alongside the
            // adjacent author-navigation button.
            Button(action: onToggleCollapse) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.vertical, 8)
                    .padding(.leading, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
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
