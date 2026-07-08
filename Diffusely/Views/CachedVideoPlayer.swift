import SwiftUI
import AVKit
import Combine

struct CachedVideoPlayer: View {
    let url: String
    let autoPlay: Bool
    let isMuted: Bool
    let onTap: (() -> Void)?
    let showsLoadingPlaceholder: Bool

    @State private var state: MediaLoadingState = .idle
    @State private var isCurrentlyPlaying = false
    @State private var loopObserver: Any?

    private let mediaCache = MediaCacheService.shared

    init(url: String, autoPlay: Bool = true, isMuted: Bool = true, showsLoadingPlaceholder: Bool = true, onTap: (() -> Void)? = nil) {
        self.url = url
        self.autoPlay = autoPlay
        self.isMuted = isMuted
        self.showsLoadingPlaceholder = showsLoadingPlaceholder
        self.onTap = onTap
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        if showsLoadingPlaceholder {
            Rectangle()
                .fill(Color.black)
                .overlay(ProgressView().tint(.white))
        } else {
            Color.clear
        }
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                loadingPlaceholder
                    .onAppear {
                        state = mediaCache.getMediaState(for: url)
                        mediaCache.loadMedia(url: url, isVideo: true)
                    }

            case .loading:
                loadingPlaceholder

            case .loaded(let content):
                if let player = content.player {
                    let video = VideoPlayer(player: player)
                    .onAppear {
                        player.isMuted = isMuted
                        if autoPlay && !isCurrentlyPlaying {
                            player.play()
                            isCurrentlyPlaying = true
                        }

                        // Set up looping
                        loopObserver = NotificationCenter.default.addObserver(
                            forName: .AVPlayerItemDidPlayToEndTime,
                            object: player.currentItem,
                            queue: .main
                        ) { _ in
                            player.seek(to: .zero)
                            player.play()
                        }
                    }
                    .onDisappear {
                        player.pause()
                        isCurrentlyPlaying = false

                        // Remove observer
                        if let observer = loopObserver {
                            NotificationCenter.default.removeObserver(observer)
                            loopObserver = nil
                        }
                    }
                    // Only attach the tap gesture when a handler exists — an
                    // always-on gesture swallows taps meant for views beneath.
                    if let onTap {
                        video.onTapGesture(perform: onTap)
                    } else {
                        video
                    }
                }

            case .failed:
                Button {
                    mediaCache.retryFailed(url: url, isVideo: true)
                } label: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            VStack {
                                Image(systemName: "play.slash")
                                    .font(.system(size: 30))
                                    .foregroundColor(.orange)
                                Text(CachedAsyncImage.retryPrompt)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Video failed to load. \(CachedAsyncImage.retryPrompt).")
            }
        }
        .onReceive(mediaCache.getStatePublisher(for: url)) { newState in
            state = newState
        }
        .onDisappear {
            // No-op for an already-loaded video (its player is kept cached and
            // paused by the inner onDisappear); drops a still-queued load.
            mediaCache.cancelLoad(url: url)
        }
    }
}

