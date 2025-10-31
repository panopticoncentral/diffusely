import SwiftUI
import AVKit

enum MediaContent: Equatable {
    case image(UIImage)
    case video(AVPlayer)

    static func == (lhs: MediaContent, rhs: MediaContent) -> Bool {
        switch (lhs, rhs) {
        case (.image(let img1), .image(let img2)):
            return img1 === img2
        case (.video(let player1), .video(let player2)):
            return player1 === player2
        default:
            return false
        }
    }

    var image: UIImage? {
        if case .image(let img) = self { return img }
        return nil
    }

    var player: AVPlayer? {
        if case .video(let player) = self { return player }
        return nil
    }
}
