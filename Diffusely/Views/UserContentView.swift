import SwiftUI

enum UserContentType: String, CaseIterable {
    case images = "Images"
    case videos = "Videos"
}

struct UserContentView: View {
    let user: CivitaiUser

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var civitaiService = CivitaiService()
    @ObservedObject private var domainManager = DomainManager.shared
    @State private var selectedContentType: UserContentType = .images
    @State private var selectedPeriod: Timeframe = .allTime
    @State private var selectedSort: FeedSort = .newest
    @State private var isFollowing: Bool = false
    @State private var isFollowLoading: Bool = false
    @State private var followError: String?

    #if os(macOS)
    // Push image details ABOVE THIS view's stack slot rather than at the
    // NavigationStack root via feedNavigator. Without this, tapping an image
    // here when UserContentView was itself pushed onto an intermediate stack
    // (e.g. opened from a post's author button) sets feedNavigator.image,
    // which replaces the root-level navigationDestination and collapses every
    // pushed view between Feed and the new image — so back returns to Feed
    // instead of this user content. Matches the pushed*-local pattern in
    // CollectionDetailView / ImageDetailView / PostDetailView.
    @State private var pushedImage: CivitaiImage?
    #endif

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
            // iOS presents this in a fullScreenCover, so we own all the chrome
            // (close button, title, filter menu, follow button). On macOS the
            // view is pushed into the NavigationStack and the equivalent
            // affordances live in `.toolbar` below.
            headerView

            if hasAPIKey {
                followButton
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
        .toolbar { macToolbar }
        #endif
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
        #if os(macOS)
        .navigationDestination(item: $pushedImage) { image in
            ImageDetailView(image: image)
        }
        #endif
    }

    @ViewBuilder
    private var feedContent: some View {
        #if os(macOS)
        MasonryGrid(
            items: civitaiService.images,
            aspectRatio: { CGFloat($0.width) / max(1, CGFloat($0.height)) }
        ) { image in
            ImageFeedItemView(
                image: image,
                isGridMode: true,
                preserveAspectRatio: true,
                // Route through THIS view's local pushedImage instead of the
                // default feedNavigator.push(image), which would replace the
                // root-level destination and collapse the stack above us.
                onSelectImage: { pushedImage = image },
                // Every thumbnail here is by `user` (we filtered by username),
                // so the username overlay tap is a no-op rather than pushing
                // a duplicate of this same view onto the stack. Also dodges
                // the feedNavigator.push(user) collapse-the-stack bug.
                onSelectUser: { _ in }
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
                    ImageFeedItemView(image: image, isGridMode: true)
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
                    ImageFeedItemView(image: image, isGridMode: false)
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

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // Close button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }

            Spacer()

            // User avatar and name
            HStack(spacing: 8) {
                avatarImage(size: 32)
                Text(user.username ?? "Unknown")
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            Spacer()

            // Filter menu
            filterMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    /// Filter (time + sort) menu — shared between the iOS in-content header
    /// and the macOS toolbar.
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
        if let imageURL = user.image, let url = URL(string: imageURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderAvatar(size: size)
                case .empty:
                    ProgressView()
                        .frame(width: size, height: size)
                @unknown default:
                    placeholderAvatar(size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            placeholderAvatar(size: size)
        }
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

    @ViewBuilder
    private func placeholderAvatar(size: CGFloat) -> some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: size * 0.44))
            )
    }

    #if os(macOS)
    /// macOS toolbar content. Extracted from the view body to keep the
    /// SwiftUI type-checker fast — chaining `.toolbar { … }` inline with the
    /// rest of the modifier stack pushes it over the timeout threshold.
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                avatarImage(size: 22)
                Text(user.username ?? "Unknown")
                    .font(.headline)
            }
        }
        if hasAPIKey {
            ToolbarItem(placement: .primaryAction) {
                macFollowButton
            }
        }
        ToolbarItem(placement: .primaryAction) {
            filterMenu
        }
    }

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
