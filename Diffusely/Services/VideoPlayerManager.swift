import Foundation
import AVFoundation
import AVKit
import SwiftUI
import Combine

@MainActor
class VideoPlayerManager: ObservableObject {
    @Published var player = AVPlayer()
    @Published var isLoading = false
    @Published var hasError = false
    @Published var currentVideoURL: String?
    @Published var currentVideoIndex: Int?
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupAudioSession()
        setupPlayer()
    }
    
    func playVideo(url: String, at index: Int) {
        // Don't reload if it's the same video
        guard currentVideoURL != url else {
            player.play()
            return
        }
        
        // Reset states
        isLoading = true
        hasError = false
        currentVideoURL = url
        currentVideoIndex = index
        
        // Cancel any existing subscriptions
        cancellables.removeAll()
        
        guard let videoURL = URL(string: url) else {
            hasError = true
            isLoading = false
            return
        }
        
        // Create new player item
        let item = AVPlayerItem(url: videoURL)
        player.replaceCurrentItem(with: item)
        
        // Ensure audio is enabled for new item
        player.isMuted = false
        player.volume = 1.0
        
        // Set up observers for the new item
        setupPlayerItemObservers(for: item)
        
        // Enable looping
        setupLooping(for: item)
        
        // Start playing
        player.play()
    }
    
    func pause() {
        player.pause()
    }
    
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentVideoURL = nil
        currentVideoIndex = nil
        isLoading = false
        hasError = false
        cancellables.removeAll()
    }
    
    private func setupPlayerItemObservers(for item: AVPlayerItem) {
        // Monitor player item status
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    self?.isLoading = false
                    self?.hasError = false
                case .failed:
                    self?.isLoading = false
                    self?.hasError = true
                case .unknown:
                    // Keep loading state
                    break
                @unknown default:
                    self?.isLoading = false
                    self?.hasError = true
                }
            }
            .store(in: &cancellables)
        
        // Monitor buffer status
        item.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEmpty in
                if !isEmpty && item.status == .readyToPlay {
                    self?.isLoading = false
                }
            }
            .store(in: &cancellables)
        
        // Fallback timeout
        Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in
                if self?.isLoading == true {
                    self?.hasError = true
                    self?.isLoading = false
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupPlayer() {
        // Ensure audio is not muted
        player.isMuted = false
        player.volume = 1.0
    }
    
    private func setupLooping(for item: AVPlayerItem) {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
            .store(in: &cancellables)
    }
}