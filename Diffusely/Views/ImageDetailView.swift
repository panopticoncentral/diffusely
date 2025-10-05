import SwiftUI

struct ImageDetailView: View {
    let image: CivitaiImage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding()
                    }

                    if let username = image.user?.username {
                        Text(username)
                            .font(.headline)
                            .foregroundColor(.white)
                    }

                    Spacer()
                }
                .background(Color.black.opacity(0.3))

                // Main content - scrollable
                ScrollView {
                    VStack(spacing: 0) {
                        // Image/Video
                        if image.isVideo {
                            let aspectRatio = CGFloat(image.width ?? 16) / CGFloat(image.height ?? 9)
                            CachedVideoPlayer(
                                url: image.detailURL,
                                autoPlay: true,
                                isMuted: false
                            )
                            .aspectRatio(aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                        } else {
                            CachedAsyncImage(url: image.detailURL)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }

                        // Stats section
                        VStack(alignment: .leading, spacing: 12) {
                            FeedItemStats(
                                likeCount: image.stats?.likeCountAllTime ?? 0,
                                heartCount: image.stats?.heartCountAllTime ?? 0,
                                laughCount: image.stats?.laughCountAllTime ?? 0,
                                cryCount: image.stats?.cryCountAllTime ?? 0,
                                commentCount: image.stats?.commentCountAllTime ?? 0,
                                dislikeCount: image.stats?.dislikeCountAllTime ?? 0
                            )

                            Divider()
                                .background(Color.white.opacity(0.2))

                            // Additional metadata
                            if let meta = image.meta {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Generation Details")
                                        .font(.headline)
                                        .foregroundColor(.white)

                                    if let prompt = meta.prompt {
                                        MetadataRow(label: "Prompt", value: prompt)
                                    }

                                    if let negativePrompt = meta.negativePrompt {
                                        MetadataRow(label: "Negative Prompt", value: negativePrompt)
                                    }

                                    if let model = meta.model {
                                        MetadataRow(label: "Model", value: model)
                                    }

                                    HStack(spacing: 16) {
                                        if let steps = meta.steps {
                                            SmallMetadataItem(label: "Steps", value: "\(steps)")
                                        }
                                        if let cfgScale = meta.cfgScale {
                                            SmallMetadataItem(label: "CFG", value: String(format: "%.1f", cfgScale))
                                        }
                                        if let seed = meta.seed {
                                            SmallMetadataItem(label: "Seed", value: "\(seed)")
                                        }
                                    }

                                    if let sampler = meta.sampler {
                                        MetadataRow(label: "Sampler", value: sampler)
                                    }

                                    if let size = meta.size {
                                        MetadataRow(label: "Size", value: size)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding()
                    }
                }
                .background(Color.black)
            }
        }
        .navigationBarHidden(true)
    }
}
