# Embedded Generation Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse the generation metadata embedded in a saved Library item's original image file and display it in a new "Embedded Metadata" section of `LibraryDetailView`, below the existing Civitai "Generation Info".

**Architecture:** A pure parser (`A1111ParametersParser`) turns the A1111 `parameters` string into an ordered `GenerationParameters` struct. A pure PNG text-chunk extractor and an ImageIO-based EXIF reader feed it raw strings; `EmbeddedMetadataReader` ties them to a coordinated, bounded file read. `LibraryDetailView` reads the local original off the main actor (`Task.detached`) and renders `EmbeddedMetadataView` when metadata is found, silently hiding it otherwise.

**Tech Stack:** Swift, SwiftUI, ImageIO, swift-testing (`import Testing`), `NSFileCoordinator`. Tests run on `platform=macOS`.

---

## File Structure

- Create: `Diffusely/Models/Civitai/EmbeddedMetadata.swift` — `EmbeddedMetadata` + `GenerationParameters` models, and the pure `A1111ParametersParser`.
- Create: `Diffusely/Services/Media/EmbeddedMetadataReader.swift` — PNG chunk extraction, EXIF extraction, and the `read(fileURL:)` entry point.
- Create: `Diffusely/Views/EmbeddedMetadataView.swift` — the SwiftUI section.
- Modify: `Diffusely/Views/LibraryDetailView.swift` — add `@State`, load on `.task`, render the section.
- Test: `DiffuselyTests/A1111ParametersParserTests.swift`
- Test: `DiffuselyTests/EmbeddedMetadataReaderTests.swift`

New files must be added to the `Diffusely` target (and test files to `DiffuselyTests`) in `Diffusely.xcodeproj`. If the project uses Xcode's automatic file synchronization (file-system-synchronized groups), placing files in the directories above is sufficient; otherwise add the file references to `project.pbxproj` manually. Verify with a build after the first file is created (Task 1, Step 6).

---

## Task 1: `GenerationParameters` model + `A1111ParametersParser`

**Files:**
- Create: `Diffusely/Models/Civitai/EmbeddedMetadata.swift`
- Test: `DiffuselyTests/A1111ParametersParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/A1111ParametersParserTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct A1111ParametersParserTests {
    // A realistic captured sample (prompt with inline LoRAs, negative, param tail).
    let sample = """
    masterpiece, best quality, <lora:detailEnhancer:0.8>, a young woman, <lora:styleX:0.5>
    Negative prompt: worst quality, bad anatomy
    Steps: 30, Sampler: Euler a Karras, CFG scale: 4.0, Seed: 818544170345672, Size: 1248x1824, Clip skip: 2, Model hash: 38FB5B8E02, Model: Nickel Saffron Manga, Version: ComfyUI
    """

    @Test func parsesPromptNegativeAndFields() {
        let result = A1111ParametersParser.parse(sample)
        #expect(result != nil)
        #expect(result?.prompt == "masterpiece, best quality, <lora:detailEnhancer:0.8>, a young woman, <lora:styleX:0.5>")
        #expect(result?.negativePrompt == "worst quality, bad anatomy")
    }

    @Test func preservesFieldOrderAndValues() {
        let fields = A1111ParametersParser.parse(sample)?.fields ?? []
        let keys = fields.map(\.key)
        #expect(keys == ["Steps", "Sampler", "CFG scale", "Seed", "Size", "Clip skip", "Model hash", "Model", "Version"])
        #expect(fields.first(where: { $0.key == "Sampler" })?.value == "Euler a Karras")
        #expect(fields.first(where: { $0.key == "Model" })?.value == "Nickel Saffron Manga")
    }

    @Test func preservesInlineLoraOrderingInPrompt() {
        let prompt = A1111ParametersParser.parse(sample)?.prompt ?? ""
        let first = prompt.range(of: "<lora:detailEnhancer:0.8>")
        let second = prompt.range(of: "<lora:styleX:0.5>")
        #expect(first != nil && second != nil)
        #expect(first!.lowerBound < second!.lowerBound)
    }

    @Test func handlesQuotedValueContainingCommas() {
        let s = "a prompt\nSteps: 20, Lora hashes: \"add_detail: abc123, styleX: def456\", Seed: 7"
        let fields = A1111ParametersParser.parse(s)?.fields ?? []
        #expect(fields.first(where: { $0.key == "Lora hashes" })?.value == "add_detail: abc123, styleX: def456")
        #expect(fields.first(where: { $0.key == "Seed" })?.value == "7")
    }

    @Test func returnsNilForNonA1111Strings() {
        #expect(A1111ParametersParser.parse("just a bare prompt with no parameter tail") == nil)
        #expect(A1111ParametersParser.parse("{\"5\": {\"inputs\": {}}}") == nil)
    }

    @Test func parsesPromptWithoutNegative() {
        let s = "only positive prompt\nSteps: 10, Sampler: DDIM"
        let result = A1111ParametersParser.parse(s)
        #expect(result?.prompt == "only positive prompt")
        #expect(result?.negativePrompt == nil)
        #expect(result?.fields.map(\.key) == ["Steps", "Sampler"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/A1111ParametersParserTests 2>&1 | tail -25`
Expected: FAIL — `cannot find 'A1111ParametersParser' in scope`.

- [ ] **Step 3: Write the models and parser**

Create `Diffusely/Models/Civitai/EmbeddedMetadata.swift`:

```swift
import Foundation

/// Generation parameters parsed from an embedded A1111-format `parameters` string.
/// `fields` is ordered to match the source so display order (and thus the order of
/// inline LoRA references inside `prompt`) is preserved.
struct GenerationParameters: Equatable {
    let prompt: String?
    let negativePrompt: String?
    let fields: [Field]

    struct Field: Equatable {
        let key: String
        let value: String
    }
}

/// Metadata extracted from an image file, before/with parsing.
struct EmbeddedMetadata: Equatable {
    enum Source: Equatable {
        case pngText(keyword: String)
        case exifUserComment
        case exifSoftware
    }

    let source: Source
    /// The verbatim extracted string (PNG chunk text or EXIF value).
    let raw: String
    /// Non-nil when `raw` was recognized as an A1111 parameters string.
    let parameters: GenerationParameters?
}

/// Parses the Automatic1111 / SD-WebUI `parameters` string format:
///
///     <positive prompt>
///     Negative prompt: <negative>
///     Steps: 30, Sampler: Euler a, CFG scale: 4, Seed: 1, Size: 512x768, Model: foo
///
/// Returns nil for strings that are not A1111-shaped (no trailing parameter line).
enum A1111ParametersParser {
    static func parse(_ string: String) -> GenerationParameters? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The parameter tail is the last line that begins with "Steps:" (A1111 always
        // emits Steps first in the tail). Everything before it is prompt / negative.
        let lines = text.components(separatedBy: .newlines)
        guard let tailIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Steps:") }) else {
            return nil
        }

        let tail = lines[tailIndex]
        let head = lines[..<tailIndex].joined(separator: "\n")

        var prompt: String?
        var negativePrompt: String?
        if let negRange = head.range(of: "Negative prompt:") {
            let p = String(head[..<negRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = p.isEmpty ? nil : p
            negativePrompt = String(head[negRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let p = head.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = p.isEmpty ? nil : p
        }

        let fields = parseFields(tail)
        guard !fields.isEmpty else { return nil }
        return GenerationParameters(prompt: prompt, negativePrompt: negativePrompt, fields: fields)
    }

    /// Splits the comma-separated `Key: value` tail, respecting double-quoted values
    /// that may themselves contain commas (e.g. `Lora hashes: "a: 1, b: 2"`).
    private static func parseFields(_ tail: String) -> [GenerationParameters.Field] {
        var pairs: [String] = []
        var current = ""
        var inQuotes = false
        for char in tail {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "," && !inQuotes {
                pairs.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { pairs.append(current) }

        return pairs.compactMap { pair -> GenerationParameters.Field? in
            guard let colon = pair.firstIndex(of: ":") else { return nil }
            let key = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { return nil }
            return GenerationParameters.Field(key: key, value: value)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/A1111ParametersParserTests 2>&1 | tail -25`
Expected: PASS — all six tests pass (`** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Models/Civitai/EmbeddedMetadata.swift DiffuselyTests/A1111ParametersParserTests.swift
git commit -m "Add A1111 parameters parser and embedded metadata models

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: Verify the iOS target also builds (new file is in target)**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. If it fails with "cannot find 'A1111ParametersParser'", the new file was not added to the `Diffusely` target — add its reference to `project.pbxproj`, then re-run.

---

## Task 2: PNG text-chunk extraction

**Files:**
- Create: `Diffusely/Services/Media/EmbeddedMetadataReader.swift`
- Test: `DiffuselyTests/EmbeddedMetadataReaderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `DiffuselyTests/EmbeddedMetadataReaderTests.swift`:

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct EmbeddedMetadataReaderTests {
    /// Builds a minimal PNG byte stream: signature + IHDR + the given tEXt chunks +
    /// IDAT + IEND. CRC values are filler (our walker skips CRC), lengths are correct.
    static func makePNG(textChunks: [(keyword: String, text: String)], includeIDATBeforeText: Bool = false) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        func appendChunk(type: String, payload: Data) {
            var len = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
            data.append(contentsOf: Array(type.utf8))
            data.append(payload)
            data.append(contentsOf: [0, 0, 0, 0]) // filler CRC
        }

        appendChunk(type: "IHDR", payload: Data(repeating: 0, count: 13))
        if includeIDATBeforeText { appendChunk(type: "IDAT", payload: Data([1, 2, 3])) }
        for chunk in textChunks {
            var payload = Data(chunk.keyword.utf8)
            payload.append(0) // null separator
            payload.append(Data(chunk.text.utf8))
            appendChunk(type: "tEXt", payload: payload)
        }
        appendChunk(type: "IEND", payload: Data())
        return data
    }

    @Test func extractsParametersChunk() {
        let png = Self.makePNG(textChunks: [("parameters", "hello\nSteps: 10")])
        let chunks = EmbeddedMetadataReader.pngTextChunks(in: png)
        #expect(chunks["parameters"] == "hello\nSteps: 10")
    }

    @Test func extractsComfyUIChunks() {
        let png = Self.makePNG(textChunks: [("prompt", "{\"5\":{}}"), ("workflow", "{\"nodes\":[]}")])
        let chunks = EmbeddedMetadataReader.pngTextChunks(in: png)
        #expect(chunks["prompt"] == "{\"5\":{}}")
        #expect(chunks["workflow"] == "{\"nodes\":[]}")
    }

    @Test func stopsAtIDATSoTextAfterImageDataIsIgnored() {
        // A text chunk placed after IDAT must not be read (we stop at IDAT).
        let png = Self.makePNG(textChunks: [("parameters", "should be ignored")], includeIDATBeforeText: true)
        let chunks = EmbeddedMetadataReader.pngTextChunks(in: png)
        #expect(chunks["parameters"] == nil)
    }

    @Test func returnsEmptyForNonPNG() {
        #expect(EmbeddedMetadataReader.pngTextChunks(in: Data([0xFF, 0xD8, 0xFF])).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: FAIL — `cannot find 'EmbeddedMetadataReader' in scope`.

- [ ] **Step 3: Write the PNG chunk extractor**

Create `Diffusely/Services/Media/EmbeddedMetadataReader.swift`:

```swift
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
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: PASS — all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/EmbeddedMetadataReader.swift DiffuselyTests/EmbeddedMetadataReaderTests.swift
git commit -m "Add PNG tEXt chunk extraction for embedded metadata

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: EXIF extraction + `read(fileURL:)` entry point

**Files:**
- Modify: `Diffusely/Services/Media/EmbeddedMetadataReader.swift`
- Test: `DiffuselyTests/EmbeddedMetadataReaderTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these tests inside the `EmbeddedMetadataReaderTests` suite in `DiffuselyTests/EmbeddedMetadataReaderTests.swift` (before the closing `}`):

```swift
    /// Writes a 1x1 JPEG carrying an EXIF UserComment to a temp file, returns its URL.
    static func makeJPEGWithUserComment(_ comment: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("emd-\(UUID().uuidString).jpg")
        let pixel = Data([0, 0, 0])
        let provider = CGDataProvider(data: pixel as CFData)!
        let cg = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 24,
                         bytesPerRow: 3, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: comment]
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    @Test func readsParametersFromPNGFile() throws {
        let png = Self.makePNG(textChunks: [("parameters", "a prompt\nNegative prompt: bad\nSteps: 20, Sampler: DDIM")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emd-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = EmbeddedMetadataReader.read(fileURL: url)
        #expect(meta?.source == .pngText(keyword: "parameters"))
        #expect(meta?.parameters?.prompt == "a prompt")
        #expect(meta?.parameters?.negativePrompt == "bad")
    }

    @Test func readsUserCommentFromJPEGFile() throws {
        let url = try Self.makeJPEGWithUserComment("a bare prompt from civitai generator")
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = EmbeddedMetadataReader.read(fileURL: url)
        #expect(meta?.source == .exifUserComment)
        #expect(meta?.raw == "a bare prompt from civitai generator")
        #expect(meta?.parameters == nil) // not A1111-shaped -> raw only
    }

    @Test func returnsNilForFileWithNoMetadata() throws {
        let png = Self.makePNG(textChunks: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emd-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(EmbeddedMetadataReader.read(fileURL: url) == nil)
    }

    @Test func returnsNilForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).png")
        #expect(EmbeddedMetadataReader.read(fileURL: url) == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: FAIL — `type 'EmbeddedMetadataReader' has no member 'read'`.

- [ ] **Step 3: Add EXIF extraction and the `read(fileURL:)` entry point**

Add these members to the `EmbeddedMetadataReader` enum in `Diffusely/Services/Media/EmbeddedMetadataReader.swift` (before the closing `}`):

```swift
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
        var coordError: NSError?
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

    /// Reads EXIF UserComment (preferred) or Software via ImageIO without decoding pixels.
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: PASS — all eight tests in the suite pass.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/EmbeddedMetadataReader.swift DiffuselyTests/EmbeddedMetadataReaderTests.swift
git commit -m "Add EXIF extraction and coordinated read entry point

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `EmbeddedMetadataView` + wire into `LibraryDetailView`

**Files:**
- Create: `Diffusely/Views/EmbeddedMetadataView.swift`
- Modify: `Diffusely/Views/LibraryDetailView.swift`

This task is UI integration; it is verified by a successful build on both platforms (the
parsing/reading logic is already covered by Tasks 1–3). There is no unit test step.

- [ ] **Step 1: Create the view**

Create `Diffusely/Views/EmbeddedMetadataView.swift`:

```swift
import SwiftUI

/// Displays generation metadata read directly from the image file, below the Civitai
/// "Generation Info". A1111-parsed fields render structured; the verbatim string is
/// always available under a collapsible Raw disclosure.
struct EmbeddedMetadataView: View {
    let metadata: EmbeddedMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Embedded Metadata")
                .font(.headline)
                .foregroundColor(.primary)

            if let params = metadata.parameters {
                if let prompt = params.prompt, !prompt.isEmpty {
                    CopyablePromptView(label: "Prompt", text: prompt)
                }
                if let negative = params.negativePrompt, !negative.isEmpty {
                    CopyablePromptView(label: "Negative Prompt", text: negative)
                }
                if !params.fields.isEmpty {
                    fieldGrid(params.fields)
                }
            }

            DisclosureGroup("Raw") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            Clipboard.copy(metadata.raw)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(metadata.raw)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func fieldGrid(_ fields: [GenerationParameters.Field]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.key)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(field.value)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add state and the loader to `LibraryDetailView`**

In `Diffusely/Views/LibraryDetailView.swift`, add a state property next to the others (after line 12, `@State private var showingRemoveConfirm = false`):

```swift
    @State private var embedded: EmbeddedMetadata?
```

Then add this method inside `LibraryDetailView` (after `loadMetadata()`, before the closing brace of the struct):

```swift
    /// Reads embedded generation metadata from the local original file off the main
    /// actor (blocking file I/O must not run on the cooperative pool). Silently does
    /// nothing for videos or when the file isn't materialized locally.
    private func loadEmbeddedMetadata(for metadata: LibraryItemMetadata) async {
        guard metadata.mediaType == .image,
              let dir = try? await LibraryContainer.shared.itemsDirectory()
        else { return }
        let fileURL = dir.appendingPathComponent(metadata.mediaFileName)
        let result = await Task.detached(priority: .utility) {
            EmbeddedMetadataReader.read(fileURL: fileURL)
        }.value
        embedded = result
    }
```

- [ ] **Step 3: Call the loader after metadata loads**

In `LibraryDetailView.loadMetadata()`, after `metadata = decoded` (currently line 159), add:

```swift
        await loadEmbeddedMetadata(for: decoded)
```

- [ ] **Step 4: Render the section**

In `LibraryDetailView.body`, find the existing Civitai section (currently lines 68-71):

```swift
                        if let genData = metadata.generationData {
                            Divider()
                            GenerationDataView(data: genData)
                        }
```

Add immediately after it:

```swift
                        if let embedded {
                            Divider()
                            EmbeddedMetadataView(metadata: embedded)
                        }
```

- [ ] **Step 5: Build on macOS**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Build on iOS Simulator**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. If either build fails with "cannot find 'EmbeddedMetadataView'", add the new file's reference to the `Diffusely` target in `project.pbxproj`.

- [ ] **Step 7: Run the full test suite**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **` — Task 1–3 suites still pass alongside the existing suites.

- [ ] **Step 8: Commit**

```bash
git add Diffusely/Views/EmbeddedMetadataView.swift Diffusely/Views/LibraryDetailView.swift
git commit -m "Show embedded generation metadata in Library detail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Manual verification (after implementation)

1. Open a saved Library item that was generated with an SD tool (most anime/art images).
2. Confirm an "Embedded Metadata" section appears below "Generation Info" with a Prompt
   that includes inline `<lora:…>` tags in their original order.
3. Expand "Raw" and confirm the verbatim string and Copy button work.
4. Open a video item and confirm no "Embedded Metadata" section appears.
5. Open an item whose original was stripped (e.g. a plain photo upload) and confirm the
   section is absent rather than empty.

## Self-review notes

- **Spec coverage:** A1111 parsing (Task 1), raw passthrough via `EmbeddedMetadata.raw` +
  Raw disclosure (Tasks 3–4), PNG + EXIF readers (Tasks 2–3), separate section below
  Generation Info (Task 4), `Task.detached` + `NSFileCoordinator` + silent hide on
  missing/evicted (Task 3 `read`, Task 4 loader), video skip (Task 4 loader), ordered
  fields preserving LoRA order (Task 1 tests). ComfyUI structured parsing intentionally
  deferred — its `prompt`/`workflow` JSON still surfaces via the Raw disclosure.
- **Type consistency:** `EmbeddedMetadata`, `GenerationParameters`, `GenerationParameters.Field`,
  `A1111ParametersParser.parse`, `EmbeddedMetadataReader.pngTextChunks` / `.read(fileURL:)`,
  `EmbeddedMetadataView(metadata:)` used consistently across tasks. Reuses existing
  `CopyablePromptView(label:text:)` and `Clipboard.copy(_:)`.
