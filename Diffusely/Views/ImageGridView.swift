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
                                        await civitaiService.loadMore()
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
                await civitaiService.fetchImages()
            }
            .task {
                if civitaiService.images.isEmpty {
                    await civitaiService.fetchImages()
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