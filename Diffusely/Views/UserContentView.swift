import SwiftUI

enum UserContentType: String, CaseIterable {
    case images = "Images"
    case videos = "Videos"
}

struct UserContentView: View {
    let user: CivitaiUser

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var domainManager = DomainManager.shared
    @State private var selectedContentType: UserContentType = .images
    @State private var selectedPeriod: Timeframe = .allTime
    @State private var selectedSort: FeedSort = .newest
    @State private var isFollowing: Bool = false
    @State private var isFollowLoading: Bool = false
    @State private var followError: String?

    private var hasAPIKey: Bool {
        APIKeyManager.shared.hasAPIKey
    }

    private var isGridLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // The avatar + name live in the toolbar's principal slot (shared
            // with macOS); the full-width Follow button stays in-content on
            // iOS where the large tap target suits the platform.
            if hasAPIKey {
                followButton
                    .padding(.top, 8)
            }
            #endif

            // Segmented Picker
            Picker("Content Type", selection: $selectedContentType) {
                ForEach(UserContentType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            #if os(macOS)
            // A 3-column segmented control stretched across a desktop window
            // looks ridiculous; constrain it and center it.
            .frame(maxWidth: 320)
            .padding(.top, 12)
            .padding(.bottom, 8)
            #else
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            #endif

            // Content Feed
            ScrollView {
                feedContent

                if civitaiService.isLoading {
                    ProgressView()
                        .padding()
                }

                if civitaiService.images.isEmpty && !civitaiService.isLoading {
                    emptyStateView
                }
            }
            .refreshable {
                await refreshContent()
            }
        }
        .background(Color(.systemBackground))
        #if os(macOS)
        .navigationTitle(user.username ?? "Unknown")
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { contentToolbar }
        .alert(
            "Couldn't update follow",
            isPresented: Binding(
                get: { followError != nil },
                set: { if !$0 { followError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { followError = nil }
        } message: {
            Text(followError ?? "")
        }
        .task {
            await loadContent()
            await checkFollowStatus()
        }
        .onChange(of: selectedContentType) { _, _ in
            Task {
                await refreshContent()
            }
        }
        .onChange(of: selectedPeriod) { _, _ in
            Task {
                await refreshContent()
            }
        }
        .onChange(of: selectedSort) { _, _ in
            Task {
                await refreshContent()
            }
        }
        .onChange(of: domainManager.domain) { _, _ in
            Task {
                await refreshContent()
            }
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        // showsUsername: false throughout — every thumbnail here is by `user`
        // (the feed is filtered by username), so the overlay would be redundant
        // and tapping it would push a duplicate of this profile.
        #if os(macOS)
        MasonryGrid(
            items: civitaiService.images,
            aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
        ) { image in
            ImageFeedItemView(
                image: image,
                isGridMode: true,
                preserveAspectRatio: true,
                showsUsername: false
            )
                .onAppear {
                    if image.id == civitaiService.images.last?.id {
                        Task { await loadMore() }
                    }
                }
        }
        #else
        if isGridLayout {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(civitaiService.images) { image in
                    ImageFeedItemView(image: image, isGridMode: true, showsUsername: false)
                        .onAppear {
                            if image.id == civitaiService.images.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(civitaiService.images) { image in
                    ImageFeedItemView(image: image, isGridMode: false, showsUsername: false)
                        .onAppear {
                            if image.id == civitaiService.images.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
        }
        #endif
    }

    /// Filter (time + sort) menu, shown in the toolbar on both platforms.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            Menu("Time") {
                ForEach(Timeframe.allCases) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        HStack {
                            Text(period.displayName)
                            if period == selectedPeriod {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("Sort") {
                ForEach(FeedSort.allCases) { sort in
                    Button {
                        selectedSort = sort
                    } label: {
                        HStack {
                            Text(sort.displayName)
                            Spacer()
                            if sort == selectedSort {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: sort.icon)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter and sort")
    }

    /// Round avatar image, sized for either the in-content iOS header (32) or
    /// the macOS toolbar's principal slot (22).
    @ViewBuilder
    private func avatarImage(size: CGFloat) -> some View {
        AvatarImage(urlString: user.image, size: size)
    }

    @ViewBuilder
    private var followButton: some View {
        Button {
            Task {
                await toggleFollow()
            }
        } label: {
            Group {
                if isFollowLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: isFollowing ? "checkmark" : "plus")
                        Text(isFollowing ? "Following" : "Follow")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .padding(.vertical, 10)
            .foregroundColor(isFollowing ? .primary : .white)
            .background(isFollowing ? Color(.secondarySystemBackground) : Color.blue)
            .cornerRadius(12)
        }
        .disabled(isFollowLoading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// Toolbar shared by both platforms: avatar + name in the principal slot,
    /// filter menu trailing. macOS additionally gets a compact Follow button
    /// (iOS keeps the full-width in-content one). Extracted from the view
    /// body to keep the SwiftUI type-checker fast — chaining `.toolbar { … }`
    /// inline with the rest of the modifier stack pushes it over the timeout
    /// threshold.
    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                avatarImage(size: 22)
                Text(user.username ?? "Unknown")
                    .font(.headline)
            }
        }
        #if os(macOS)
        if hasAPIKey {
            ToolbarItem(placement: .primaryAction) {
                macFollowButton
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            filterMenu
        }
    }

    #if os(macOS)
    /// Compact Follow/Following button for the macOS toolbar. Unlike the iOS
    /// full-width version, this renders as a normal toolbar button — sized to
    /// its label, not the window. Word-only (no glyph) because a bare `+` in
    /// the toolbar reads as "add" rather than "follow".
    @ViewBuilder
    private var macFollowButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            if isFollowLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(isFollowing ? "Following" : "Follow")
            }
        }
        .disabled(isFollowLoading)
        .help(isFollowing ? "Unfollow this user" : "Follow this user")
    }
    #endif

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedContentType == .images ? "photo" : "video")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No \(selectedContentType.rawValue.lowercased()) found")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 60)
    }

    private func loadContent() async {
        guard let username = user.username else { return }

        let isVideos = selectedContentType == .videos
        await civitaiService.fetchImages(
            videos: isVideos,
            period: selectedPeriod,
            sort: selectedSort,
            username: username
        )
    }

    private func loadMore() async {
        guard let username = user.username else { return }

        let isVideos = selectedContentType == .videos
        await civitaiService.loadMoreImages(
            videos: isVideos,
            period: selectedPeriod,
            sort: selectedSort,
            username: username
        )
    }

    private func refreshContent() async {
        civitaiService.clear()
        await loadContent()
    }

    private func checkFollowStatus() async {
        guard hasAPIKey else { return }

        do {
            let followingIds = try await civitaiService.getFollowingUserIds()
            isFollowing = followingIds.contains(user.id)
        } catch {
            // Status unknown - button still shows, defaulting to "Follow".
            print("checkFollowStatus failed: \(error)")
        }
    }

    private func toggleFollow() async {
        guard !isFollowLoading else { return }

        isFollowLoading = true
        do {
            try await civitaiService.toggleFollowUser(targetUserId: user.id)
            isFollowing.toggle()
        } catch {
            print("toggleFollow failed: \(error)")
            followError = "The request didn't go through. Check your connection and that your API key is set in Settings, then try again."
        }
        isFollowLoading = false
    }
}
