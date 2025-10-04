import SwiftUI
import AVKit
import Combine

struct CachedVideoPlayer: View {
    let url: String
    let autoPlay: Bool
    let isMuted: Bool
    let onTap: (() -> Void)?

    @StateObject private var mediaCache = MediaCacheService.shared
    @State private var isCurrentlyPlaying = false

    init(url: String, autoPlay: Bool = true, isMuted: Bool = true, onTap: (() -> Void)? = nil) {
        self.url = url
        self.autoPlay = autoPlay
        self.isMuted = isMuted
        self.onTap = onTap
    }

    var body: some View {
        Group {
            switch mediaCache.getMediaState(for: url) {
            case .idle:
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )
                    .onAppear {
                        mediaCache.loadMedia(url: url, isVideo: true)
                    }

            case .loading:
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )

            case .loaded(let content):
                if let player = content.player {
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
                        mediaCache.retryFailed(url: url, isVideo: true)
                    }
            }
        }
        .onReceive(mediaCache.$mediaStates) { _ in
            // Ensures view updates when media state changes
        }
    }
}

