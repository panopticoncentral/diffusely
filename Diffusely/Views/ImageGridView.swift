//
//  ImageGridView.swift
//  Diffusely
//
//  Created by Claude on 8/20/25.
//

import SwiftUI

struct ImageGridView: View {
    @StateObject private var civitaiService = CivitaiService()
    @State private var selectedImage: CivitaiImage?
    @State private var selectedIndex: Int = 0
    @State private var selectedRating: ContentRating = .pg13
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
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
        return Array(repeating: GridItem(.flexible(), spacing: 1), count: columnCount)
    }
    
    var body: some View {
        ZStack {
            // Full-screen grid with edge-to-edge content
            ScrollView {
                LazyVGrid(columns: columns, spacing: 1) { // Minimal spacing like Photos
                    ForEach(Array(civitaiService.images.enumerated()), id: \.element.id) { index, image in
                        PhotosGridThumbnail(image: image)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .onTapGesture {
                                selectedImage = image
                                selectedIndex = index
                            }
                            .onAppear {
                                if image.id == civitaiService.images.last?.id {
                                    Task {
                                        await civitaiService.loadMore(browsingLevel: selectedRating.browsingLevelValue)
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
                await civitaiService.fetchImages(browsingLevel: selectedRating.browsingLevelValue)
            }
            .task {
                if civitaiService.images.isEmpty {
                    await civitaiService.fetchImages(browsingLevel: selectedRating.browsingLevelValue)
                }
            }
            .onChange(of: selectedRating) { _, newRating in
                civitaiService.clear()
                Task {
                    await civitaiService.fetchImages(browsingLevel: newRating.browsingLevelValue)
                }
            }
            
            // Floating transparent title at top
            VStack {
                HStack {
                    Text("Diffusely")
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
            
            // Floating Photos-style toolbar at bottom
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PhotosFloatingToolbar(selectedRating: $selectedRating)
                    Spacer()
                }
                .padding(.bottom, 20)
            }
        }
        .fullScreenCover(item: $selectedImage) { _ in
            PhotosCarouselView(
                images: civitaiService.images,
                selectedIndex: $selectedIndex,
                isPresented: Binding(
                    get: { selectedImage != nil },
                    set: { if !$0 { selectedImage = nil } }
                )
            )
        }
    }
}