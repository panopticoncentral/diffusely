import SwiftUI

struct AuthorContentGrid: View {
    let images: [CivitaiImage]
    let posts: [CivitaiPost]
    let collectionType: String
    /// When true, each thumbnail shows a context menu. Set only by the
    /// collection grid so the main feed and author profile remain clean.
    var showsItemContextMenus: Bool = false
    /// Provided by the parent on Mac so taps push at the parent's level rather
    /// than at the root (where `feedNavigator.push` would clobber the parent's
    /// own stack entry). Nil on iOS — the children fall back to fullScreenCover.
    var onSelectImage: ((CivitaiImage) -> Void)? = nil
    var onSelectPost: ((CivitaiPost) -> Void)? = nil
    /// Same story for the per-thumbnail username overlay tap.
    var onSelectUser: ((CivitaiUser) -> Void)? = nil

    var body: some View {
        if collectionType == "Image" {
            MasonryGrid(
                items: images,
                aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
            ) { image in
                ImageFeedItemView(
                    image: image,
                    isGridMode: true,
                    preserveAspectRatio: true,
                    onSelectImage: onSelectImage.map { selector in { selector(image) } },
                    onSelectUser: onSelectUser,
                    onSelectPost: onSelectPost,
                    showsContextMenu: showsItemContextMenus
                )
            }
        } else {
            MasonryGrid(
                items: posts,
                aspectRatio: { post in
                    guard let first = post.safeImages.first, first.height > 0 else { return 1 }
                    return CGFloat(first.width) / CGFloat(first.height)
                }
            ) { post in
                PostThumbnailView(
                    post: post,
                    onSelect: onSelectPost.map { selector in { selector(post) } },
                    showsContextMenu: showsItemContextMenus
                )
            }
        }
    }
}

struct PostThumbnailView: View {
    let post: CivitaiPost
    /// When provided, runs instead of the platform-default presentation. The
    /// parent uses this to push `PostDetailView` at its own stack level (so
    /// back returns to the collection rather than to the root).
    var onSelect: (() -> Void)? = nil
    /// When true, the thumbnail gains a right-click / long-press context
    /// menu that mirrors `PostDetailView`'s "…" menu. Set only by the
    /// collection grid.
    var showsContextMenu: Bool = false
    #if os(iOS)
    @State private var showingDetail = false
    #endif
    @State private var showingCollectionPicker = false
    @ObservedObject private var librarySaveService = LibrarySaveService.shared

    @ViewBuilder
    var body: some View {
        if showsContextMenu {
            bodyCore.contextMenu { menuContent }
        } else {
            bodyCore
        }
    }

    @ViewBuilder
    private var bodyCore: some View {
        ZStack {
            if let firstImage = post.safeImages.first {
                CachedAsyncImage(url: firstImage.thumbnailURL)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let onSelect = onSelect {
                onSelect()
                return
            }
            #if os(iOS)
            showingDetail = true
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingDetail) {
            PostDetailView(post: post)
        }
        #endif
        .sheet(isPresented: $showingCollectionPicker) {
            ManageCollectionsSheet(target: .post(post)) {
                showingCollectionPicker = false
            }
        }
    }

    /// Mirrors `PostDetailView`'s ellipsis menu plus the optional Remove item.
    @ViewBuilder
    private var menuContent: some View {
        Button {
            librarySaveService.savePost(post)
        } label: {
            Label(
                librarySaveService.isSavingPost(post) ? "Saving Post…" : "Save Post to Library",
                systemImage: "square.and.arrow.down.on.square"
            )
        }
        .disabled(librarySaveService.isSavingPost(post))

        if APIKeyManager.shared.hasAPIKey {
            Button {
                showingCollectionPicker = true
            } label: {
                Label("Manage Collections", systemImage: "folder")
            }
        }

    }
}
