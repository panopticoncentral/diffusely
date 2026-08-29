import SwiftUI

/// The Tags segment of the Following section: the tags the user has chosen to
/// follow, each opening a feed scoped to that tag.
///
/// Civitai has no server-side tag following, so this list is entirely local
/// (`FollowedTagsStore`) — there is nothing to sync and nothing to load.
struct TagsView: View {
    @ObservedObject private var store = FollowedTagsStore.shared
    @State private var showingAddTag = false

    var body: some View {
        content
            .navigationTitle("Tags")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddTag = true
                    } label: {
                        Label("Add Tag", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddTag) {
                AddTagSheet()
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.tags.isEmpty {
            FollowingMessageView(
                systemImage: "number",
                title: "You're not following any tags",
                message: "Add a tag here, or follow one from the tags on any image.",
                actionTitle: "Add Tag"
            ) { showingAddTag = true }
        } else {
            listView
        }
    }

    private var listView: some View {
        List {
            ForEach(store.tags) { tag in
                // Opens on images; the feed itself has an Images/Videos toggle.
                NavigationLink(value: Route.tag(id: tag.id, name: tag.name, videos: false)) {
                    FollowedTagRowView(tag: tag)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.unfollow(id: tag.id)
                    } label: {
                        Label("Unfollow", systemImage: "minus.circle")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        store.unfollow(id: tag.id)
                    } label: {
                        Label("Unfollow", systemImage: "minus.circle")
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

/// One row: a `#` glyph + tag name. Tags have no avatar, so the glyph stands in
/// for the circular image in `FollowedUserRowView` to keep the two segments'
/// rows the same height.
private struct FollowedTagRowView: View {
    let tag: FollowedTag

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
            Text(tag.name)
                .font(.headline)
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
