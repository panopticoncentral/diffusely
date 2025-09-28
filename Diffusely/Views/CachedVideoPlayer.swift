import SwiftUI
import AVKit
import Combine

struct CachedVideoPlayer: View {
    let url: String
    let autoPlay: Bool
    let isMuted: Bool
    let onTap: (() -> Void)?

    @StateObject private var videoCache = VideoCacheService.shared
    @State private var isCurrentlyPlaying = false

    init(url: String, autoPlay: Bool = true, isMuted: Bool = true, onTap: (() -> Void)? = nil) {
        self.url = url
        self.autoPlay = autoPlay
        self.isMuted = isMuted
        self.onTap = onTap
    }

    var body: some View {
        Group {
            switch videoCache.getVideoState(for: url) {
            case .idle:
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )
                    .onAppear {
                        videoCache.loadVideo(url: url)
                    }

            case .loading:
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )

            case .loaded(let player):
                VideoPlayer(player: player)
                .onAppear {
                    player.isMuted = isMuted
                    if autoPlay && !isCurrentlyPlaying {
                        player.play()
                        isCurrentlyPlaying = true
                    }
                }
                .onDisappear {
                    player.pause()
                    isCurrentlyPlaying = false
                }
                .onTapGesture {
                    onTap?()
                }

            case .failed(_):
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        VStack {
                            Image(systemName: "play.slash")
                                .font(.system(size: 30))
                                .foregroundColor(.orange)
                            Text("Tap to retry")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    )
                    .onTapGesture {
                        videoCache.retryFailedVideo(url: url)
                    }
            }
        }
        .onReceive(videoCache.$videoStates) { _ in
            // Ensures view updates when video state changes
        }
    }
}

