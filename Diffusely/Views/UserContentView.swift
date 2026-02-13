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
    @State private var selectedContentType: UserContentType = .images
    @State private var selectedRating: ContentRating = .pg13
    @State private var selectedPeriod: Timeframe = .allTime
    @State private var selectedSort: FeedSort = .newest

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
            // Header
            headerView

            // Segmented Picker
            Picker("Content Type", selection: $selectedContentType) {
                ForEach(UserContentType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Content Feed
            ScrollView {
                if isGridLayout {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(civitaiService.images) { image in
                            ImageFeedItemView(image: image, isGridMode: true)
                                .onAppear {
                                    if image.id == civitaiService.images.last?.id {
                                        Task {
                                            await loadMore()
                                        }
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
                                        Task {
                                            await loadMore()
                                        }
                                    }
                                }
                        }
                    }
                }

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
        .task {
            await loadContent()
        }
        .onChange(of: selectedContentType) { _, _ in
            Task {
                await refreshContent()
            }
        }
        .onChange(of: selectedRating) { _, _ in
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
                if let imageURL = user.image, let url = URL(string: imageURL) {
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
                                .frame(width: 32, height: 32)
                        @unknown default:
                            placeholderAvatar
                        }
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    placeholderAvatar
                }

                Text(user.username ?? "Unknown")
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            Spacer()

            // Filter menu
            Menu {
                Menu("Content") {
                    ForEach(ContentRating.allCases) { rating in
                        Button {
                            selectedRating = rating
                        } label: {
                            HStack {
                                Text(rating.displayName)
                                if rating == selectedRating {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

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
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "person.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 14))
            )
    }

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
            browsingLevel: selectedRating.browsingLevelValue,
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
            browsingLevel: selectedRating.browsingLevelValue,
            period: selectedPeriod,
            sort: selectedSort,
            username: username
        )
    }

    private func refreshContent() async {
        civitaiService.clear()
        await loadContent()
    }
}
