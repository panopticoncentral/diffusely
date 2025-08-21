//
//  ImageThumbnailView.swift
//  Diffusely
//
//  Created by Claude on 8/20/25.
//

import SwiftUI

struct ImageThumbnailView: View {
    let image: CivitaiImage
    
    var body: some View {
        Group {
            if image.isVideo, let url = URL(string: image.url) {
                VideoThumbnailView(url: url)
            } else {
                AsyncImage(url: URL(string: image.url)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.8)
                        )
                }
            }
        }
        .clipped()
        .cornerRadius(8)
        .overlay(
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let stats = image.stats {
                        HStack(spacing: 4) {
                            if let likes = stats.likeCount, likes > 0 {
                                Label("\(likes)", systemImage: "heart.fill")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(4)
                        .background(.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(4)
                    }
                }
            }
        )
    }
}