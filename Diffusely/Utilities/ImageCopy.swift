#if os(macOS)
import AppKit
import Nuke
import UniformTypeIdentifiers

/// macOS clipboard helpers for remote feed/detail imagery. Centralizes the two
/// paths an image reaches the pasteboard so the feed cell, the feed detail, and
/// any future caller stay consistent:
///   • `copyRemoteImage` — an eager write for explicit menu actions.
///   • `remoteImageProviders` — a lazy `NSItemProvider` for the standard Copy
///     command (`.onCopyCommand`), which only does work if Copy actually fires
///     and, unlike a view-level ⌘C shortcut, leaves text-selection Copy intact.
/// Both load through the shared Nuke pipeline, so a visible image is a cache hit.
enum ImageCopy {
    static func copyRemoteImage(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task {
            guard let nsImage = try? await ImagePipeline.shared.image(for: request(for: url)) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }
    }

    static func remoteImageProviders(urlString: String) -> [NSItemProvider] {
        guard let url = URL(string: urlString) else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            Task {
                if let nsImage = try? await ImagePipeline.shared.image(for: request(for: url)),
                   let jpeg = nsImage.jpegData(compressionQuality: 0.95) {
                    completion(jpeg, nil)
                } else {
                    completion(nil, CocoaError(.fileReadCorruptFile))
                }
            }
            return nil
        }
        return [provider]
    }

    private static func request(for url: URL) -> ImageRequest {
        ImageRequest(url: url, processors: [.resize(width: AppImagePipeline.maxDimension)])
    }
}
#endif
