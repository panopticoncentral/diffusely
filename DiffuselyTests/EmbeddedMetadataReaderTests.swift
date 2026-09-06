import Testing
import Foundation
import ImageIO
import CoreGraphics
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

    @Test func skipsZTXtAndITXtChunks() {
        // Build a PNG whose only text-bearing chunks are zTXt and iTXt — both must be
        // ignored (we only read uncompressed tEXt).
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func appendChunk(type: String, payload: Data) {
            var len = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
            data.append(contentsOf: Array(type.utf8))
            data.append(payload)
            data.append(contentsOf: [0, 0, 0, 0])
        }
        appendChunk(type: "IHDR", payload: Data(repeating: 0, count: 13))
        appendChunk(type: "zTXt", payload: Data("parameters".utf8) + Data([0, 0]) + Data([1, 2, 3]))
        appendChunk(type: "iTXt", payload: Data("prompt".utf8) + Data([0]) + Data("ignored".utf8))
        appendChunk(type: "IEND", payload: Data())
        let chunks = EmbeddedMetadataReader.pngTextChunks(in: data)
        #expect(chunks.isEmpty)
    }

    @Test func stopsCleanlyOnTruncatedChunk() {
        // A chunk that declares a length longer than the remaining bytes must not crash
        // or read out of bounds — the walker should stop and return what it has.
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR (well-formed)
        var ihdrLen = UInt32(13).bigEndian
        withUnsafeBytes(of: &ihdrLen) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array("IHDR".utf8))
        data.append(Data(repeating: 0, count: 13))
        data.append(contentsOf: [0, 0, 0, 0])
        // tEXt chunk declaring a huge length but with only a few payload bytes present
        var bogusLen = UInt32(9999).bigEndian
        withUnsafeBytes(of: &bogusLen) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array("tEXt".utf8))
        data.append(Data("parameters".utf8) + Data([0]) + Data("abc".utf8))
        let chunks = EmbeddedMetadataReader.pngTextChunks(in: data)
        #expect(chunks["parameters"] == nil) // truncated chunk is not emitted
    }

    @Test func skipsTextChunkWithNoNullSeparator() {
        // A tEXt chunk lacking the keyword/text null separator is malformed and dropped.
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func appendChunk(type: String, payload: Data) {
            var len = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
            data.append(contentsOf: Array(type.utf8))
            data.append(payload)
            data.append(contentsOf: [0, 0, 0, 0])
        }
        appendChunk(type: "IHDR", payload: Data(repeating: 0, count: 13))
        appendChunk(type: "tEXt", payload: Data("no-null-separator-here".utf8)) // no 0 byte
        appendChunk(type: "IEND", payload: Data())
        let chunks = EmbeddedMetadataReader.pngTextChunks(in: data)
        #expect(chunks.isEmpty)
    }

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
        #expect(meta?.container == .png)
        #expect(meta?.fields["parameters"] != nil)
        #expect(meta?.parameters?.prompt == "a prompt")
        #expect(meta?.parameters?.negativePrompt == "bad")
    }

    @Test func readsUserCommentFromJPEGFile() throws {
        let url = try Self.makeJPEGWithUserComment("a bare prompt from civitai generator")
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = EmbeddedMetadataReader.read(fileURL: url)
        #expect(meta?.container == .jpeg)
        #expect(meta?.fields["UserComment"] != nil)
        #expect(meta?.raw == "a bare prompt from civitai generator")
        #expect(meta?.parameters == nil) // not A1111-shaped -> raw only
        #expect(meta?.format == .unknown)
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

    @Test func parsesA1111ShapedUserCommentFromJPEG() throws {
        let comment = "a prompt\nNegative prompt: bad\nSteps: 20, Sampler: DDIM"
        let url = try Self.makeJPEGWithUserComment(comment)
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = EmbeddedMetadataReader.read(fileURL: url)
        #expect(meta?.container == .jpeg)
        #expect(meta?.fields["UserComment"] != nil)
        #expect(meta?.parameters?.prompt == "a prompt")
        #expect(meta?.parameters?.fields.map(\.key) == ["Steps", "Sampler"])
        #expect(meta?.format == .automatic1111)
    }

    @Test func returnsNilForWhitespaceOnlyUserComment() throws {
        let url = try Self.makeJPEGWithUserComment("   \n  ")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EmbeddedMetadataReader.read(fileURL: url) == nil)
    }

    @Test func pngParametersKeywordWinsOverComfyChunks() throws {
        let png = Self.makePNG(textChunks: [("workflow", "{\"nodes\":[]}"), ("parameters", "p\nSteps: 5")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emd-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EmbeddedMetadataReader.read(fileURL: url)?.fields["parameters"] != nil)
    }

    @Test func pngCommentWinsOverWorkflowWhenNoParameters() throws {
        let png = Self.makePNG(textChunks: [("workflow", "{\"nodes\":[]}"), ("Comment", "some text")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emd-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EmbeddedMetadataReader.read(fileURL: url)?.fields["Comment"] != nil)
    }

    // MARK: read(data:) — the decrypted-media counterpart used once a Library
    // read goes through `LibraryFileStore.readMedia` (Data, not a URL).
    // Mirrors the `read(fileURL:)` cases above so both entry points agree.

    @Test func dataReadExtractsParametersFromPNGBytes() {
        let png = Self.makePNG(textChunks: [("parameters", "a prompt\nNegative prompt: bad\nSteps: 20, Sampler: DDIM")])
        let meta = EmbeddedMetadataReader.read(data: png)
        #expect(meta?.container == .png)
        #expect(meta?.fields["parameters"] != nil)
        #expect(meta?.parameters?.prompt == "a prompt")
        #expect(meta?.parameters?.negativePrompt == "bad")
    }

    @Test func dataReadExtractsUserCommentFromJPEGBytes() throws {
        let url = try Self.makeJPEGWithUserComment("a bare prompt from civitai generator")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)

        let meta = EmbeddedMetadataReader.read(data: data)
        #expect(meta?.container == .jpeg)
        #expect(meta?.fields["UserComment"] != nil)
        #expect(meta?.raw == "a bare prompt from civitai generator")
        #expect(meta?.parameters == nil) // not A1111-shaped -> raw only
        #expect(meta?.format == .unknown)
    }

    @Test func dataReadReturnsNilForDataWithNoMetadata() {
        let png = Self.makePNG(textChunks: [])
        #expect(EmbeddedMetadataReader.read(data: png) == nil)
    }

    @Test func dataReadReturnsNilForEmptyData() {
        #expect(EmbeddedMetadataReader.read(data: Data()) == nil)
    }

    @Test func dataReadAgreesWithFileReadForTheSameBytes() throws {
        let png = Self.makePNG(textChunks: [("parameters", "p\nSteps: 5")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emd-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(EmbeddedMetadataReader.read(data: png) == EmbeddedMetadataReader.read(fileURL: url))
    }

    // MARK: - Format detection (Task 8)

    /// The txt2img graph from ComfyRecipeBuilderTests, as the JSON ComfyUI would write.
    static let minimalPromptJSON = #"""
    {"3":{"class_type":"KSampler","inputs":{"model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0],"seed":42,"steps":20,"cfg":7,"sampler_name":"euler","scheduler":"normal","denoise":1}},
     "4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"sdxl_base.safetensors"}},
     "5":{"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
     "6":{"class_type":"CLIPTextEncode","inputs":{"text":"a cat","clip":["4",1]}},
     "7":{"class_type":"CLIPTextEncode","inputs":{"text":"blurry","clip":["4",1]}},
     "8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},
     "9":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":"out"}}}
    """#
    static let minimalWorkflowJSON = #"{"nodes":[{"id":3,"type":"KSampler","title":"Main Sampler"}],"links":[]}"#

    @Test func allChunksAreRetained() {
        let png = Self.makePNG(textChunks: [("parameters", "p\nSteps: 1, Sampler: a"), ("prompt", Self.minimalPromptJSON)])
        let meta = EmbeddedMetadataReader.read(data: png)
        #expect(meta?.fields.count == 2)
    }

    @Test func a1111WinsWhenBothFormatsPresent() {
        let meta = EmbeddedMetadataReader.metadata(
            fields: ["parameters": "p\nSteps: 1, Sampler: a", "prompt": Self.minimalPromptJSON], container: .png)
        #expect(meta?.format == .automatic1111)
        #expect(meta?.comfy == nil)
        #expect(meta?.raw == "p\nSteps: 1, Sampler: a")
    }

    @Test func promptAloneIsComfyWithRecipe() {
        let meta = EmbeddedMetadataReader.metadata(fields: ["prompt": Self.minimalPromptJSON], container: .png)
        #expect(meta?.format == .comfyUI)
        #expect(meta?.parameters == nil)
        #expect(meta?.comfy?.error == nil)
        #expect(meta?.comfy?.recipe?.passes.count == 1)
        #expect(meta?.raw == Self.minimalPromptJSON)
    }

    @Test func workflowAloneIsComfyWithoutRecipe() {
        let meta = EmbeddedMetadataReader.metadata(fields: ["workflow": Self.minimalWorkflowJSON], container: .png)
        #expect(meta?.format == .comfyUI)
        #expect(meta?.comfy?.recipe == nil)
        #expect(meta?.comfy?.error == .noPromptGraph)
        #expect(meta?.comfy?.workflowJSON == Self.minimalWorkflowJSON)
    }

    @Test func rawPrefersWorkflowOverPrompt() {
        let meta = EmbeddedMetadataReader.metadata(
            fields: ["prompt": Self.minimalPromptJSON, "workflow": Self.minimalWorkflowJSON], container: .png)
        #expect(meta?.raw == Self.minimalWorkflowJSON)
        #expect(meta?.comfy?.graph?.nodes["3"]?.title == "Main Sampler")
    }

    @Test func userCommentJSONRoutesToComfy() {
        let meta = EmbeddedMetadataReader.metadata(fields: ["UserComment": Self.minimalPromptJSON], container: .jpeg)
        #expect(meta?.format == .comfyUI)
        #expect(meta?.comfy?.promptJSON == Self.minimalPromptJSON)
        #expect(meta?.comfy?.recipe?.passes.count == 1)
    }

    @Test func userCommentWrapperObjectIsSplit() {
        let wrapper = #"{"prompt": \#(Self.minimalPromptJSON), "workflow": \#(Self.minimalWorkflowJSON)}"#
        let meta = EmbeddedMetadataReader.metadata(fields: ["UserComment": wrapper], container: .jpeg)
        #expect(meta?.format == .comfyUI)
        #expect(meta?.comfy?.promptJSON != nil)
        #expect(meta?.comfy?.workflowJSON != nil)
        #expect(meta?.comfy?.recipe?.passes.count == 1)
    }

    @Test func modelTagPromptPrefixRoutesToComfy() {
        let meta = EmbeddedMetadataReader.metadata(fields: ["Model": "prompt:" + Self.minimalPromptJSON], container: .webp)
        #expect(meta?.format == .comfyUI)
        #expect(meta?.comfy?.recipe?.passes.count == 1)
    }

    @Test func malformedPromptIsComfyWithError() {
        let meta = EmbeddedMetadataReader.metadata(fields: ["prompt": "{{{"], container: .png)
        #expect(meta == nil || meta?.format == .unknown) // "{{{" is not a graph; falls through to unknown
        let meta2 = EmbeddedMetadataReader.metadata(fields: ["prompt": #"{"1":{"class_type":"A","inputs":{"x":[NaN}}}"#], container: .png)
        #expect(meta2?.format == .comfyUI)
        #expect(meta2?.comfy?.error == .malformedJSON)
    }

    @Test func unknownFormatKeepsRaw() {
        let meta = EmbeddedMetadataReader.metadata(fields: ["Comment": "just a note"], container: .png)
        #expect(meta?.format == .unknown)
        #expect(meta?.raw == "just a note")
        #expect(meta?.parameters == nil && meta?.comfy == nil)
    }

    @Test func emptyFieldsYieldNil() {
        #expect(EmbeddedMetadataReader.metadata(fields: ["parameters": "   "], container: .png) == nil)
        #expect(EmbeddedMetadataReader.metadata(fields: [:], container: .jpeg) == nil)
    }
}
