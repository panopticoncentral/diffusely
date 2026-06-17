import Foundation
import ImageIO

/// Reads embedded generation metadata from a local image file. Pure extraction helpers
/// (`pngTextChunks`) are split out for testing; `read(fileURL:)` adds the coordinated,
/// bounded file read.
enum EmbeddedMetadataReader {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Extracts uncompressed `tEXt` chunks (keyword -> text) from PNG `data`, walking
    /// chunks until the first `IDAT` (generation text precedes image data in practice).
    /// Returns empty for non-PNG data. `iTXt`/`zTXt` are skipped (compressed/encoded);
    /// the tools we target write the generation record as plain `tEXt`.
    static func pngTextChunks(in data: Data) -> [String: String] {
        guard data.count > 8, Array(data.prefix(8)) == pngSignature else { return [:] }

        var result: [String: String] = [:]
        var offset = 8
        // Copies the entire input. Callers are responsible for bounding input size; this
        // function does not cap it. The file-reading entry point reads only a bounded prefix.
        let bytes = [UInt8](data)

        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                       | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let typeStart = offset + 4
            guard typeStart + 4 <= bytes.count else { break }
            let type = String(bytes: bytes[typeStart..<typeStart + 4], encoding: .ascii) ?? ""
            let dataStart = typeStart + 4
            guard dataStart + length <= bytes.count else { break }

            if type == "IDAT" || type == "IEND" { break }

            if type == "tEXt" {
                let payload = Array(bytes[dataStart..<dataStart + length])
                if let nullIndex = payload.firstIndex(of: 0) {
                    let keyword = String(bytes: payload[..<nullIndex], encoding: .isoLatin1) ?? ""
                    let textBytes = payload[(nullIndex + 1)...]
                    let text = String(bytes: textBytes, encoding: .utf8)
                        ?? String(bytes: textBytes, encoding: .isoLatin1) ?? ""
                    if !keyword.isEmpty { result[keyword] = text }
                }
            }

            offset = dataStart + length + 4 // skip data + 4-byte CRC
        }
        return result
    }

    /// Caps how many bytes we read from a PNG header looking for text chunks. The
    /// generation `tEXt` chunk sits right after IHDR in practice, so this is ample and
    /// avoids loading multi-MB pixel data.
    private static let pngPrefixCap = 1 << 20 // 1 MiB

    /// Reads embedded metadata from a local file. Coordinates the read with
    /// `NSFileCoordinator` (iCloud-backed) and returns nil for missing/evicted files,
    /// unsupported containers, or files with no recognized metadata.
    ///
    /// Call this OFF the main actor / cooperative pool (e.g. `Task.detached`): it does
    /// blocking file I/O.
    static func read(fileURL: URL) -> EmbeddedMetadata? {
        var coordError: NSError? // Any coordination failure leaves result nil (the desired contract).
        var result: EmbeddedMetadata?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordError) { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard let magic = try? handle.read(upToCount: 8), magic.count == 8 else { return }

            if Array(magic) == pngSignature {
                try? handle.seek(toOffset: 0)
                let prefix = (try? handle.read(upToCount: pngPrefixCap)) ?? Data()
                result = embeddedMetadata(fromPNG: prefix)
            } else {
                result = embeddedMetadata(fromEXIFFile: url)
            }
        }
        return result
    }

    /// Selects the highest-priority text chunk and parses it.
    private static func embeddedMetadata(fromPNG data: Data) -> EmbeddedMetadata? {
        let chunks = pngTextChunks(in: data)
        // Priority: the human-readable A1111 record first, then ComfyUI graph JSON.
        for keyword in ["parameters", "Comment", "prompt", "workflow"] {
            if let text = chunks[keyword], !text.isEmpty {
                return EmbeddedMetadata(source: .pngText(keyword: keyword),
                                        raw: text,
                                        parameters: A1111ParametersParser.parse(text))
            }
        }
        return nil
    }

    /// Reads the EXIF UserComment via ImageIO without decoding pixels. (Civitai's EXIF
    /// Software field holds a useless generation UUID, so it is intentionally ignored.)
    private static func embeddedMetadata(fromEXIFFile url: URL) -> EmbeddedMetadata? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let comment = exif[kCGImagePropertyExifUserComment] as? String,
           !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return EmbeddedMetadata(source: .exifUserComment,
                                    raw: comment,
                                    parameters: A1111ParametersParser.parse(comment))
        }
        return nil
    }
}
