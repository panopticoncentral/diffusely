import Foundation
import UniformTypeIdentifiers

/// Sniffs the real container of media bytes. Library media is stored under a
/// cosmetic `.jpeg` name (Civitai's `original=true` URL keeps the uploader's
/// bytes verbatim), so nothing may trust the extension.
enum MediaContainer: Equatable, Hashable {
    case png, jpeg, webp, other

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func detect(_ data: Data) -> MediaContainer {
        let head = [UInt8](data.prefix(12))
        if head.count >= 8, Array(head[0..<8]) == pngSignature { return .png }
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xD8 { return .jpeg }
        if head.count >= 12,
           Array(head[0..<4]) == Array("RIFF".utf8),
           Array(head[8..<12]) == Array("WEBP".utf8) { return .webp }
        return .other
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpeg"
        case .webp: return "webp"
        case .other: return "bin"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .webp: return .webP
        case .other: return .data
        }
    }
}
