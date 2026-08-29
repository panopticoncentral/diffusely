import SwiftUI

struct FollowingView: View {
    @StateObject private var civitaiService = CivitaiService()
    @StateObject private var store = FollowingStore()
    @Environment(\.modelContext) private var modelContext

    @State private var showingSettings = false

    var body: some View {
        content
            .navigationTitle("Users")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            #endif
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                store.configure(
                    dataSource: civitaiService,
                    cache: AuthorCache(modelContext: modelContext)
                )
                await store.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noAPIKey:
            FollowingMessageView(
                systemImage: "person.crop.circle.badge.questionmark",
                title: "Sign in to see who you follow",
                message: "Add your Civitai API key to load the creators you follow.",
                actionTitle: "Open Settings"
            ) { showingSettings = true }
        case .empty:
            FollowingMessageView(
                systemImage: "person.2",
                title: "You're not following anyone yet",
                message: "Creators you follow on Civitai will appear here."
            )
        case .error(let description):
            FollowingMessageView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load your follows",
                message: description,
                actionTitle: "Retry"
            ) { Task { await store.refresh() } }
        case .loaded:
            listView
        }
    }

    private var listView: some View {
        List {
            ForEach(store.rows) { row in
                NavigationLink(value: Route.user(row.civitaiUser)) {
                    FollowedUserRowView(user: row.civitaiUser, failed: row.failed)
                }
                .buttonStyle(.plain)
            }

            if store.resolvingCount > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Resolving \(store.resolvingCount) more…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
    }
}

/// One row: circular avatar + username, mirroring `AuthorSectionHeader`.
private struct FollowedUserRowView: View {
    let user: CivitaiUser
    let failed: Bool

    // No manual chevron: the enclosing NavigationLink adds the disclosure
    // indicator automatically on iOS, and list chevrons aren't a Mac idiom.
    var body: some View {
        HStack(spacing: 12) {
            avatar
            Text(user.username ?? (failed ? "Unavailable" : "Unknown Artist"))
                .font(.headline)
                .foregroundStyle(failed ? .secondary : .primary)
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        AvatarImage(urlString: user.image, size: 40)
    }
}
