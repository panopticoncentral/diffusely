import SwiftUI

struct PostsFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @State private var selectedPost: CivitaiPost?
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Sticky header that scrolls with content
                    HStack {
                        Text("Posts")
                            .font(.system(size: 34, weight: .bold, design: .default))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                        Spacer()

                        FeedFilterMenu(
                            selectedRating: $selectedRating,
                            selectedPeriod: $selectedPeriod,
                            selectedSort: $selectedSort
                        )
                    }
                    .background(Color(.systemBackground))

                    ForEach(Array(civitaiService.posts.enumerated()), id: \.element.id) { index, post in
                        PostsFeedItemView(
                            post: post,
                            onTap: { selectedPost = post }
                        )
                        .onAppear {
                            // Load more content when reaching the end
                            if post.id == civitaiService.posts.last?.id {
                                Task {
                                    await civitaiService.loadMorePosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 50)
                .padding(.bottom, 20)

                if civitaiService.isLoading {
                    ProgressView()
                        .padding()
                }

                if let error = civitaiService.error {
                    Text("Error: \(error.localizedDescription)")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .ignoresSafeArea(.all)
            .refreshable {
                civitaiService.clear()
                await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
            }
            .task {
                if civitaiService.posts.isEmpty {
                    await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedRating) { _, _ in refreshPosts() }
            .onChange(of: selectedPeriod) { _, _ in refreshPosts() }
            .onChange(of: selectedSort) { _, _ in refreshPosts() }
        }
    }

    private func refreshPosts() {
        civitaiService.clear()
        Task {
            await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
        }
    }
}