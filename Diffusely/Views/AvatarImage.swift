import SwiftUI
import NukeUI

/// Circular user avatar loaded through the shared Nuke pipeline (dedup + durable
/// disk cache), replacing the per-site `AsyncImage`s in the author header, the
/// user profile, and the following list. Shows a person placeholder while
/// loading and on failure.
struct AvatarImage: View {
    let url: URL?
    var size: CGFloat = 40

    /// Convenience for the common case of a `String?` image URL from the API.
    init(urlString: String?, size: CGFloat = 40) {
        self.url = urlString.flatMap(URL.init(string:))
        self.size = size
    }

    init(url: URL?, size: CGFloat = 40) {
        self.url = url
        self.size = size
    }

    var body: some View {
        Group {
            if let url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .overlay(Image(systemName: "person.fill").foregroundColor(.gray))
    }
}
