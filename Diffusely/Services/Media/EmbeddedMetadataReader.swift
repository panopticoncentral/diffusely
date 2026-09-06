import Foundation
import ImageIO

/// Reads embedded generation metadata from a local image file. Pure extraction
/// helpers (`pngTextChunks`, `metadata(fields:container:)`) are split out for
/// testing; the `read` entry points add the bounded, coordinated file read.
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

    /// Caps how many bytes we read from a file header looking for text. The
    /// generation `tEXt` chunk sits right after IHDR, and a JPEG's APP1 segment
    /// is at most 64 KiB, so this is ample and avoids loading pixel data.
    private static let headerPrefixCap = 1 << 20 // 1 MiB

    /// Reads embedded metadata from a local file. Coordinates the read with
    /// `NSFileCoordinator` (iCloud-backed) and returns nil for missing/evicted files,
    /// unsupported containers, or files with no recognized metadata.
    ///
    /// Call this OFF the main actor / cooperative pool (e.g. `Task.detached`): it does
    /// blocking file I/O and then parses any ComfyUI graph it finds.
    static func read(fileURL: URL) -> EmbeddedMetadata? {
        var coordError: NSError? // Any coordination failure leaves result nil (the desired contract).
        var result: EmbeddedMetadata?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordError) { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: headerPrefixCap), prefix.count >= 8 else { return }
            let container = MediaContainer.detect(prefix)
            switch container {
            case .png:
                result = metadata(fields: pngTextChunks(in: prefix), container: .png)
            default:
                let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return }
                var fields = exifFields(from: source)
                if container == .jpeg { repairUserComment(in: &fields, jpegBytes: prefix) }
                result = metadata(fields: fields, container: container)
            }
        }
        return result
    }

    /// Reads embedded generation metadata from already-in-memory bytes — the
    /// decrypted-media counterpart to `read(fileURL:)` for a Library store that
    /// can only vend `Data`, never a plaintext on-disk URL, once encrypted. No
    /// `NSFileCoordinator` (the bytes are already fully in memory), but still CPU
    /// work worth keeping off the main actor, matching `read(fileURL:)`.
    static func read(data: Data) -> EmbeddedMetadata? {
        guard data.count >= 8 else { return nil }
        let container = MediaContainer.detect(data)
        switch container {
        case .png:
            return metadata(fields: pngTextChunks(in: Data(data.prefix(headerPrefixCap))), container: .png)
        default:
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
            var fields = exifFields(from: source)
            // Only the header prefix: the scanner copies what it is handed into
            // a [UInt8], and APP1 is at most 64 KiB and sits near the start —
            // handing it the whole image copied every JPEG opened without a
            // UserComment (the common case). Matches `read(fileURL:)`.
            if container == .jpeg {
                repairUserComment(in: &fields, jpegBytes: Data(data.prefix(headerPrefixCap)))
            }
            return metadata(fields: fields, container: container)
        }
    }

    /// ImageIO's string decode of UserComment can come back empty or with
    /// replacement characters for oddly-encoded writers. For JPEGs, fall back to
    /// the raw tag bytes and decode them ourselves.
    private static func repairUserComment(in fields: inout [String: String], jpegBytes: Data) {
        let current = fields["UserComment"]
        guard current == nil || current!.contains("\u{FFFD}") else { return }
        guard let raw = JPEGExifScanner.userCommentBytes(in: jpegBytes),
              let decoded = ExifUserCommentDecoder.decode(raw),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        fields["UserComment"] = decoded
    }

    /// EXIF `UserComment` and TIFF `Model` via ImageIO, without decoding pixels.
    /// (Civitai's EXIF `Software` holds a useless generation UUID; ignored.)
    private static func exifFields(from source: CGImageSource) -> [String: String] {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var fields: [String: String] = [:]
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let comment = exif[kCGImagePropertyExifUserComment] as? String, !comment.isEmpty {
            fields["UserComment"] = comment
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String, !model.isEmpty {
            fields["Model"] = model
        }
        return fields
    }

    // MARK: Format detection

    /// Classifies the recognized fields and parses what the format allows.
    /// Ordered `canParse`: A1111 first, then ComfyUI, else unknown. Returns nil
    /// when nothing non-blank was found.
    static func metadata(fields rawFields: [String: String], container: MediaContainer) -> EmbeddedMetadata? {
        let fields = rawFields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !fields.isEmpty else { return nil }

        for key in ["parameters", "Comment", "UserComment"] {
            if let text = fields[key], let params = A1111ParametersParser.parse(text) {
                return EmbeddedMetadata(fields: fields, container: container, format: .automatic1111,
                                        raw: text, parameters: params, comfy: nil)
            }
        }

        let comfy = comfyJSONFields(fields)
        if comfy.prompt != nil || comfy.workflow != nil {
            return EmbeddedMetadata(fields: fields, container: container, format: .comfyUI,
                                    raw: comfy.workflow ?? comfy.prompt ?? "",
                                    parameters: nil,
                                    comfy: ComfyPayload.make(prompt: comfy.prompt, workflow: comfy.workflow))
        }

        let raw = fields["parameters"] ?? fields["Comment"] ?? fields["UserComment"]
            ?? fields.sorted(by: { $0.key < $1.key })[0].value
        return EmbeddedMetadata(fields: fields, container: container, format: .unknown,
                                raw: raw, parameters: nil, comfy: nil)
    }

    /// Locates ComfyUI `prompt` / `workflow` JSON wherever a tool stashed it:
    /// their own PNG chunks, EXIF `UserComment` (bare or wrapped as
    /// `{"prompt":…, "workflow":…}`), or the TIFF `Model` tag with a `prompt:`
    /// prefix (Civitai's WebP variant, comfy.metadata.ts:99).
    static func comfyJSONFields(_ fields: [String: String]) -> (prompt: String?, workflow: String?) {
        var prompt = fields["prompt"].flatMap { looksLikeComfyPrompt($0) ? $0 : nil }
        var workflow = fields["workflow"].flatMap { looksLikeComfyWorkflow($0) ? $0 : nil }

        if let comment = fields["UserComment"] {
            if let wrapped = unwrapComfyEnvelope(comment) {
                prompt = prompt ?? wrapped.prompt
                workflow = workflow ?? wrapped.workflow
            } else if prompt == nil, looksLikeComfyPrompt(comment) {
                prompt = comment
            } else if workflow == nil, looksLikeComfyWorkflow(comment) {
                workflow = comment
            }
        }
        if prompt == nil, let model = fields["Model"], model.hasPrefix("prompt:") {
            let json = String(model.dropFirst("prompt:".count))
            if looksLikeComfyPrompt(json) { prompt = json }
        }
        return (prompt, workflow)
    }

    /// A `{"prompt": {…}, "workflow": {…}}` envelope, re-serialized per part.
    private static func unwrapComfyEnvelope(_ text: String) -> (prompt: String?, workflow: String?)? {
        guard let root = ComfyGraphParser.decodeLenient(text) as? [String: Any] else { return nil }
        let promptObj = root["prompt"] as? [String: Any]
        let workflowObj = root["workflow"] as? [String: Any]
        guard promptObj != nil || workflowObj != nil else { return nil }
        func serialize(_ obj: [String: Any]?) -> String? {
            guard let obj, let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        let p = serialize(promptObj)
        return (p.flatMap { looksLikeComfyPrompt($0) ? $0 : nil }, serialize(workflowObj))
    }

    /// A top-level object with at least one value carrying `class_type`. Falls
    /// back to a textual sniff so a broken-but-obviously-Comfy chunk still gets
    /// classified (and can then carry a `.malformedJSON` error).
    static func looksLikeComfyPrompt(_ text: String) -> Bool {
        if let root = ComfyGraphParser.decodeLenient(text) as? [String: Any] {
            return root.values.contains { ($0 as? [String: Any])?["class_type"] is String }
        }
        let head = text.prefix(1)
        return head == "{" && text.contains("\"class_type\"")
    }

    /// A litegraph document: an object with a `nodes` array.
    static func looksLikeComfyWorkflow(_ text: String) -> Bool {
        guard let root = ComfyGraphParser.decodeLenient(text) as? [String: Any] else { return false }
        return root["nodes"] is [Any]
    }
}
