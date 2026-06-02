import Foundation
import AVFoundation
import Nuke
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Nuke decoder for the case where a still-poster URL is mis-served as raw video
/// bytes (the CDN sometimes ignores `transcode=true,anim=false`). Detects video
/// payloads and extracts frame 0 via AVFoundation so the tile shows a poster
/// instead of failing. Normal image bytes are left to Nuke's default decoders.
struct VideoFrameImageDecoder: ImageDecoding {
    // `static let` initialization runs exactly once and is thread-safe, so
    // concurrent first-callers can't double-register the decoder.
    private static let registration: Void = {
        ImageDecoderRegistry.shared.register { context in
            let contentType = (context.urlResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")
            return isVideo(contentType: contentType, data: context.data) ? VideoFrameImageDecoder() : nil
        }
    }()

    /// Registers the decoder with Nuke's shared registry exactly once.
    static func registerOnce() {
        _ = registration
    }

    /// Pure detection: video if the content-type starts with `video/`, or the
    /// bytes are an ISO-BMFF/QuickTime container (`ftyp` box at offset 4).
    static func isVideo(contentType: String?, data: Data) -> Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        guard data.count >= 12 else { return false }
        // Index relative to startIndex so a non-zero-based Data slice can't read
        // the wrong bytes. Data's `==` compares content, not indices.
        let start = data.startIndex
        return data[start.advanced(by: 4)..<start.advanced(by: 8)] == Data("ftyp".utf8)
    }

    enum DecodeError: Error { case noFrame }

    func decode(_ data: Data) throws -> ImageContainer {
        guard let image = Self.extractFrame(from: data) else { throw DecodeError.noFrame }
        return ImageContainer(image: image)
    }

    /// Writes the bytes to a temp file (AVURLAsset needs a URL) and pulls a frame.
    private static func extractFrame(from data: Data) -> PlatformImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try data.write(to: tmp) } catch { return nil }

        let asset = AVURLAsset(url: tmp)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = [CMTime(seconds: 0.5, preferredTimescale: 600), .zero]
        for time in times {
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            #if canImport(UIKit)
            return PlatformImage(cgImage: cg)
            #elseif canImport(AppKit)
            return PlatformImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            #endif
        }
        return nil
    }
}
