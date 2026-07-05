import AVFoundation
import SwiftUI

/// Produces a still poster frame for a *remote* video without downloading the
/// whole file. `AVURLAsset` over HTTP issues byte-range reads, and Civitai's
/// transcoded mp4s are faststart (moov atom at the front) with range support, so
/// `AVAssetImageGenerator` fetches only the header + first keyframe (tens of KB)
/// rather than the full ~1 MB. This is why the grid uses this instead of loading
/// the mp4 through Nuke, which would download the entire file per cell.
///
/// Frames are cached in memory keyed by URL; `NSCache` evicts under pressure.
enum VideoPosterProvider {
    private static let cache = NSCache<NSString, PlatformImage>()

    /// The poster frame for `urlString`, or nil if none could be extracted.
    /// `maxDimension` caps the decoded frame size (grid cells are small).
    static func poster(for urlString: String, maxDimension: CGFloat = 600) async -> PlatformImage? {
        let key = urlString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = URL(string: urlString) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if maxDimension > 0 {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        // Nearest keyframe to the requested time — no precise seek, minimal reads.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // A small offset skips black opening frames; fall back to frame 0.
        let times = [CMTime(seconds: 0.5, preferredTimescale: 600), .zero]
        for time in times {
            guard let cg = try? await generator.image(at: time).image else { continue }
            #if canImport(UIKit)
            let image = PlatformImage(cgImage: cg)
            #elseif canImport(AppKit)
            let image = PlatformImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            #endif
            cache.setObject(image, forKey: key)
            return image
        }
        return nil
    }
}
