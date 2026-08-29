import SwiftUI

/// Searches Civitai's tag list (`tag.getAll`) so a tag can be followed without
/// first finding an image that carries it. Picking a result follows it and
/// dismisses; tags already followed are shown checked and inert.
struct AddTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var store = FollowedTagsStore.shared

    @State private var query = ""
    @State private var results: [CivitaiTag] = []
    @State private var isSearching = false
    /// The in-flight debounced search, cancelled whenever `query` changes so a
    /// slow earlier request can't land after a newer one.
    @State private var searchTask: Task<Void, Never>?

    /// Long enough that typing a word doesn't fire a request per keystroke,
    /// short enough to feel immediate once you stop.
    private let debounce = Duration.milliseconds(300)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Tag")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .searchable(text: $query, prompt: "Search tags")
                .onChange(of: query) { _, newValue in
                    scheduleSearch(for: newValue)
                }
                .onDisappear { searchTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            FollowingMessageView(
                systemImage: query.isEmpty ? "magnifyingglass" : "questionmark.circle",
                title: query.isEmpty ? "Search for a tag" : "No tags found",
                message: query.isEmpty
                    ? "Type a tag name to find it on Civitai."
                    : "No tag matches “\(query)”."
            )
        } else {
            List(results) { tag in
                resultRow(for: tag)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func resultRow(for tag: CivitaiTag) -> some View {
        let followed = store.isFollowing(id: tag.id)
        Button {
            store.follow(FollowedTag(id: tag.id, name: tag.name))
            dismiss()
        } label: {
            HStack {
                Text(tag.name)
                    .foregroundStyle(followed ? .secondary : .primary)
                Spacer()
                if followed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(followed)
    }

    private func scheduleSearch(for newQuery: String) {
        searchTask?.cancel()

        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let found = await civitaiService.searchTags(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
