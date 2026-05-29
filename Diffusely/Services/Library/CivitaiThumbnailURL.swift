import Foundation

/// Derives a width-limited, static-JPEG thumbnail URL on the Civitai CDN from a
/// stored library `originalCDNURL` of the form
/// `https://image.civitai.com/<bucket>/<uuid>/original=true/<id>.<ext>`.
/// Returns nil if the URL is not in that expected shape (caller falls back to
/// the iCloud original).
enum CivitaiThumbnailURL {
    static func thumbnail(fromOriginal original: String, isVideo: Bool, width: Int) -> String? {
        var components = original.components(separatedBy: "/")
        // Need at least scheme//host/uuid/transform/filename.
        guard components.count >= 5 else { return nil }
        let transformIndex = components.count - 2
        let filenameIndex = components.count - 1
        // The library only ever stores the `original=true` transform; bail if absent.
        guard components[transformIndex].contains("original=true") else { return nil }

        let id = (components[filenameIndex] as NSString).deletingPathExtension
        if isVideo {
            components[transformIndex] = "transcode=true,anim=false,skip=4,width=\(width)"
        } else {
            components[transformIndex] = "anim=false,width=\(width),optimized=true"
        }
        components[filenameIndex] = "\(id).jpeg"   // always request a static JPEG frame
        return components.joined(separator: "/")
    }
}
