import SwiftUI
import AVKit

/// Plays a personal-library video from the local/iCloud container, downloading it
/// on demand first (AVPlayer cannot drive iCloud materialization itself, so the
/// loader waits until the file is `.current` before building the player).
struct LibraryVideoPlayer: View {
    let itemID: Int
    let mediaFileName: String
    var autoPlay: Bool = true
    var isMuted: Bool = false

    @StateObject private var loader = LibraryMediaLoader()
    @State private var loopObserver: Any?

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .downloading:
                ZStack {
                    Rectangle().fill(Color.black)
                    if case .downloading = loader.state {
                        VStack(spacing: 6) {
                            Image(systemName: "icloud.and.arrow.down").foregroundColor(.white)
                            ProgressView().tint(.white)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            case .video(let player):
                VideoPlayer(player: player)
                    .onAppear {
                        player.isMuted = isMuted
                        if autoPlay { player.play() }
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
                        if let observer = loopObserver {
                            NotificationCenter.default.removeObserver(observer)
                            loopObserver = nil
                        }
                    }
            case .failed:
                Button {
                    loader.load(itemID: itemID, mediaFileName: mediaFileName)
                } label: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "play.slash")
                                    .font(.title2)
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
        .onAppear {
            loader.load(itemID: itemID, mediaFileName: mediaFileName)
        }
        .onDisappear { loader.cancel() }
    }
}
