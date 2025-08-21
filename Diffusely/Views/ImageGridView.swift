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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    private var columns: [GridItem] {
        let columnCount: Int
        switch horizontalSizeClass {
        case .compact:
            columnCount = 2
        case .regular:
            columnCount = 4
        default:
            columnCount = 3
        }
        return Array(repeating: GridItem(.flexible()), count: columnCount)
    }
    
    var body: some View {
        NavigationSplitView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(civitaiService.images) { image in
                        ImageThumbnailView(image: image)
                            .aspectRatio(1, contentMode: .fit)
                            .onTapGesture {
                                selectedImage = image
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
                .padding(.horizontal, 8)
                
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
            .refreshable {
                await civitaiService.fetchImages(refresh: true)
            }
            .task {
                if civitaiService.images.isEmpty {
                    await civitaiService.fetchImages()
                }
            }
        } detail: {
            if let selectedImage = selectedImage {
                ImageDetailView(image: selectedImage)
            } else {
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Select an image to view details")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(item: $selectedImage) { image in
            if horizontalSizeClass == .compact {
                ImageDetailView(image: image)
            }
        }
    }
}