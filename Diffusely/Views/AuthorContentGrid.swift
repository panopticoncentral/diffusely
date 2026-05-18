import SwiftUI

struct AuthorContentGrid: View {
    let images: [CivitaiImage]
    let posts: [CivitaiPost]
    let collectionType: String
    var onRequestRemove: ((CollectionItemType) -> Void)? = nil

    private let postColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        if collectionType == "Image" {
            MasonryGrid(
                items: images,
                aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
            ) { image in
                ImageFeedItemView(image: image, isGridMode: true, preserveAspectRatio: true)
                    .contextMenu {
                        if APIKeyManager.shared.hasAPIKey, let onRequestRemove {
                            Button(role: .destructive) {
                                onRequestRemove(.image(id: image.id))
                            } label: {
                                Label("Remove from Collection", systemImage: "trash")
                            }
                        }
                    }
            }
        } else {
            LazyVGrid(columns: postColumns, spacing: 2) {
                ForEach(posts) { post in
                    PostThumbnailView(post: post)
                        .contextMenu {
                            if APIKeyManager.shared.hasAPIKey, let onRequestRemove {
                                Button(role: .destructive) {
                                    onRequestRemove(.post(id: post.id))
                                } label: {
                                    Label("Remove from Collection", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct PostThumbnailView: View {
    let post: CivitaiPost
    @State private var showingDetail = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let firstImage = post.safeImages.first {
                    CachedAsyncImage(url: firstImage.thumbnailURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }

                // Multi-image indicator
                if post.imageCount > 1 {
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 2) {
                                Image(systemName: "square.stack.fill")
                                    .font(.caption2)
                                Text("\(post.imageCount)")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        }
                        .padding(6)
                        Spacer()
                    }
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingDetail = true
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        #if os(iOS)
        .fullScreenCover(isPresented: $showingDetail) {
            PostDetailView(post: post)
        }
        #else
        .sheet(isPresented: $showingDetail) {
            PostDetailView(post: post)
        }
        #endif
    }
}
