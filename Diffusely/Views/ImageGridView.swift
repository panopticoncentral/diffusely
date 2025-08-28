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
        NavigationStack {
            ZStack {
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
                .navigationTitle("Diffusely")
                .navigationBarTitleDisplayMode(.large)
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
                
                // Floating Photos-style toolbar
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