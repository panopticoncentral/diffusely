//
//  ImageDetailView.swift
//  Diffusely
//
//  Created by Claude on 8/20/25.
//

import SwiftUI

struct ImageDetailView: View {
    let image: CivitaiImage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingMetadata = false
    
    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularSizeContent
            } else {
                NavigationView {
                    compactSizeContent
                        .navigationTitle("Image Details")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") {
                                    dismiss()
                                }
                            }
                        }
                }
            }
        }
    }
    
    private var regularSizeContent: some View {
        HStack(alignment: .top, spacing: 20) {
            Group {
                if image.isVideo, let url = URL(string: image.fullURL) {
                    VideoPlayerView(url: url)
                        .frame(maxHeight: 400)
                } else {
                    AsyncImage(url: URL(string: image.fullURL)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView()
                            .frame(maxHeight: 400)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .cornerRadius(12)
            
            VStack(alignment: .leading, spacing: 16) {
                metadataContent
                Spacer()
            }
            .frame(maxWidth: 300)
        }
        .padding()
    }
    
    private var compactSizeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if image.isVideo, let url = URL(string: image.fullURL) {
                        VideoPlayerView(url: url)
                            .frame(height: 300)
                    } else {
                        AsyncImage(url: URL(string: image.fullURL)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ProgressView()
                                .frame(height: 300)
                        }
                    }
                }
                .cornerRadius(12)
                
                metadataContent
                Spacer()
            }
            .padding()
        }
    }
    
    private var metadataContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let username = image.username {
                    Label(username, systemImage: "person.circle")
                        .font(.headline)
                }
                
                Spacer()
                
                Button(action: { showingMetadata.toggle() }) {
                    Image(systemName: "info.circle")
                }
            }
            
            HStack(spacing: 20) {
                if let likes = image.stats.likeCount {
                    Label("\(likes)", systemImage: "heart")
                }
                if let comments = image.stats.commentCount {
                    Label("\(comments)", systemImage: "message")
                }
                if let hearts = image.stats.heartCount {
                    Label("\(hearts)", systemImage: "heart.fill")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            
            if showingMetadata, let meta = image.meta {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generation Details")
                        .font(.headline)
                    
                    if let prompt = meta.prompt {
                        Text("Prompt:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(prompt)
                            .font(.caption)
                            .padding(.bottom, 4)
                    }
                    
                    if let model = meta.model {
                        HStack {
                            Text("Model:")
                                .fontWeight(.semibold)
                            Text(model)
                        }
                        .font(.caption)
                    }
                    
                    HStack {
                        if let steps = meta.steps {
                            Text("Steps: \(steps)")
                        }
                        if let seed = meta.seed {
                            Text("Seed: \(seed)")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(8)
            }
        }
    }
}