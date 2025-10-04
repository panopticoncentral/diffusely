import SwiftUI

struct PostsFeedView: View {
    @StateObject private var civitaiService = CivitaiService()
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
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
                            post: post
                        )
                        .onAppear {
                            if post.id == civitaiService.posts.last?.id {
                                Task {
                                    await loadPosts()
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
                await refreshPosts()
            }
            .task {
                if civitaiService.posts.isEmpty {
                    await loadPosts()
                }
            }
            .onChange(of: selectedRating) { _, _ in Task { await refreshPosts() } }
            .onChange(of: selectedPeriod) { _, _ in Task { await refreshPosts() } }
            .onChange(of: selectedSort) { _, _ in Task { await refreshPosts() } }
        }
    }

    private func loadPosts() async {
        await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
    }

    private func refreshPosts() async {
        civitaiService.clear()
        await civitaiService.fetchPosts(browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
    }
}
