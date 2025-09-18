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
                CachedVideoPlayerView(
                    player: player,
                    autoPlay: autoPlay,
                    isMuted: isMuted,
                    onTap: onTap
                )
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

struct CachedVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let autoPlay: Bool
    let isMuted: Bool
    let onTap: (() -> Void)?

    func makeUIView(context: Context) -> CachedVideoPlayerUIView {
        let view = CachedVideoPlayerUIView()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
        view.playerLayer = playerLayer
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: CachedVideoPlayerUIView, context: Context) {
        uiView.playerLayer?.player = player
        uiView.onTap = onTap
    }
}

class CachedVideoPlayerUIView: UIView {
    var playerLayer: AVPlayerLayer?
    var onTap: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onTap?()
    }
}