import SwiftUI

struct ImageGridView: View {
    @StateObject private var civitaiService = CivitaiService()
    @State private var selected: CivitaiImage?
    @State private var selectedIndex: Int = 0
    @State private var selectedRating: ContentRating = .g
    @State private var selectedPeriod: Timeframe = .week
    @State private var selectedSort: ImageSort = .mostReactions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let videos: Bool
    
    private var columns: [GridItem] {
        let columnCount: Int
        switch horizontalSizeClass {
        case .compact:
            columnCount = 3 // More like Photos app on iPhone
        case .regular:
            columnCount = 5 // More like Photos app on iPad
        default:
            columnCount = 4
        }
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }
    
    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) { // Minimal spacing like Photos
                    ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                        ImageThumbnail(image: image)
                            .aspectRatio(1, contentMode: .fit)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selected = image
                                selectedIndex = index
                            }
                            .onAppear {
                                if image.id == civitaiService.images.last?.id {
                                    Task {
                                        await civitaiService.loadMore(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                                    }
                                }
                            }
                    }
                }
                .padding(.top, 80) // Space for floating title
                .padding(.bottom, 100) // Space for floating toolbar
                
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
                await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
            }
            .task {
                if civitaiService.images.isEmpty {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedRating) { _, newRating in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: newRating.browsingLevelValue, period: selectedPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedPeriod) { _, newPeriod in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: newPeriod, sort: selectedSort)
                }
            }
            .onChange(of: selectedSort) { _, newSort in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(videos: videos, browsingLevel: selectedRating.browsingLevelValue, period: selectedPeriod, sort: newSort)
                }
            }
            
            // Floating transparent title at top
            VStack {
                HStack {
                    Text(videos ? "Videos" : "Images")
                        .font(.system(size: 34, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    Spacer()
                }
                .background {
                    // Gradient fade from semi-transparent to completely transparent
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.15),
                            Color.black.opacity(0.05),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(.all, edges: .top)
                }
                Spacer()
            }
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    FiltersToolbar(selectedRating: $selectedRating, selectedPeriod: $selectedPeriod, selectedSort: $selectedSort)
                    Spacer()
                }
                .padding(.bottom, 20)
            }
        }
        .fullScreenCover(item: $selected) { _ in
            ImageCarouselView(
                images: civitaiService.images,
                selectedIndex: $selectedIndex,
                isPresented: Binding(
                    get: { selected != nil },
                    set: { if !$0 { selected = nil } }
                )
            )
        }
    }
}
