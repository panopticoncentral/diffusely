//
//  PhotosGridThumbnail.swift
//  Diffusely
//
//  Created by Claude on 8/27/25.
//

import SwiftUI

struct PhotosGridThumbnail: View {
    let image: CivitaiImage
    
    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.1))
            .overlay {
                AsyncImage(url: URL(string: image.fullURL)) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure(_):
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                            .font(.title2)
                    case .empty:
                        ProgressView()
                            .scaleEffect(0.8)
                    @unknown default:
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    }
                }
            }
            .clipped()
    }
}