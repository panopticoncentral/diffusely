import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Memory-efficient image downsampling via ImageIO. The full image is never decoded
/// into memory - only a thumbnail at the requested maximum dimension is produced.
enum ImageDownsampler {
    static func downsample(data: Data, maxDimension: CGFloat) -> PlatformImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        #if canImport(UIKit)
        return PlatformImage(cgImage: downsampledImage)
        #elseif canImport(AppKit)
        return PlatformImage(cgImage: downsampledImage, size: NSSize(width: downsampledImage.width, height: downsampledImage.height))
        #endif
    }
}
