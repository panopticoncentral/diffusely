# ComfyUI Recipe View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse the ComfyUI graph embedded in Library images into a readable, ordered "recipe" of sampling passes, with a node inspector and export, so the user can learn how an image was made and load its workflow back into ComfyUI.

**Architecture:** Three pure layers — `EmbeddedMetadataReader` (extract every text field, sniff container, detect format) → `ComfyGraphParser` (JSON → typed DAG) → `ComfyRecipeBuilder` (walk backwards from outputs, one pass per sampler) — feeding two SwiftUI views: an inline `ComfyRecipeView` in the Library detail scroll and a pushed `ComfyNodeInspectorView`. Parsed data is view-only; nothing touches sidecars or the SwiftData index.

**Tech Stack:** Swift 6, SwiftUI (iOS + macOS targets), Swift Testing (`@Suite`/`@Test`/`#expect`), ImageIO, `JSONSerialization`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-04-comfyui-recipe-view-design.md`

## Global Constraints

- Both targets must build: `Diffusely` for macOS and for iOS Simulator. Check both before claiming a UI task done.
- No file I/O or graph parsing on the main actor. The existing `Task.detached` in `LibraryDetailView.loadEmbeddedMetadata` is the only place media bytes are read for this feature.
- Navigation is value-based: new screens are `Route` cases rendered by `RouteDestinationView` in `Diffusely/Views/AppNavigation.swift`. No ad-hoc `navigationDestination`.
- Never run `DiffuselyUITests` (it drives the live Mac). Unit tests only: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/<Suite> 2>&1 | tail -25`
- iOS build check: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | tail -5` (substitute any device from `xcrun simctl list devices available` if that name is absent).
- The Xcode project uses synchronized folders: creating a `.swift` file under `Diffusely/` or `DiffuselyTests/` adds it to the target. Do not edit `project.pbxproj`.
- Commit locally after each task; do not push. End every commit message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `A1111ParametersParser` is not modified. Existing A1111 behaviour (fields, `raw`, `parameters`) is preserved.

**Deviations from the spec, decided while planning (each is small and noted where it lands):**
- `ComfyParseError` gains a third case, `.noPromptGraph`, for images carrying only a `workflow` chunk (no API graph to walk). The spec's Section 1 says `workflow` alone yields `.comfyUI`; this is how the view explains why there is no recipe.
- `SamplerSettings` fields are `var … = nil` rather than `let`, so the builder can fill them incrementally. `seed` is `UInt64?` because ComfyUI seeds are uint64 and `JSONSerialization` preserves them exactly (verified: objCType `Q`).
- Real-workflow fixtures are Swift string literals in `DiffuselyTests/Fixtures/ComfyFixtures.swift`, not `.json` resources, so nothing depends on test-bundle resource copying.
- The export menu also offers "Copy API Prompt JSON" (the `prompt` chunk) whenever it exists, since ComfyUI's current frontend loads API-format JSON and it is what the fixture task needs.

---

## File Structure

New:
- `Diffusely/Services/Media/MediaContainer.swift` — magic-byte sniffer; `fileExtension` and `utType`. Used by the reader, the export menu, and ⌘C.
- `Diffusely/Models/Civitai/ComfyGraph.swift` — `ComfyNodeID`, `ComfyValue`, `ComfyInput`, `ComfyNodeInput`, `ComfyNode`, `DanglingLink`, `ComfyGraph` (+ `make(nodes:)`, `numericIDSort`).
- `Diffusely/Services/Media/ComfyGraphParser.swift` — `ComfyParseError`, `ComfyGraphParser` (JSON → `ComfyGraph`, `cleanBadJSON`, link disambiguation, `workflow` title enrichment).
- `Diffusely/Services/Media/ComfySchema.swift` — every node-class name the builder recognizes, plus `ComfyRole`.
- `Diffusely/Models/Civitai/ComfyRecipe.swift` — `ComfyRecipe`, `SamplingPass`, `SamplerSettings`, `ModelStep`, `ConditioningText`, `LatentSource`, `LoraResource`, `ResourceSummary`.
- `Diffusely/Services/Media/ComfyRecipeBuilder.swift` — the backwards walk.
- `Diffusely/Services/Media/ExifUserCommentDecoder.swift` — `ExifUserCommentDecoder` (charset header + BOM) and `JPEGExifScanner` (APP1 → tag 0x9286 bytes).
- `Diffusely/Views/MetadataFieldGrid.swift` — the key/value grid extracted from `EmbeddedMetadataView` so both formats share it.
- `Diffusely/Views/ComfyRecipeView.swift` — resources, pass cards, actions, export menu.
- `Diffusely/Views/ComfyNodeInspectorView.swift` — `ComfyInspectorPayload` and the pushed list.
- `Diffusely/Utilities/DataDocument.swift` — `FileDocument` wrapper for `.fileExporter`.
- `DiffuselyTests/MediaContainerTests.swift`, `ComfyGraphParserTests.swift`, `ComfyRecipeBuilderTests.swift`, `ExifUserCommentDecoderTests.swift`, `Fixtures/ComfyFixtures.swift`, `ComfyFixtureTests.swift`.

Modified:
- `Diffusely/Models/Civitai/EmbeddedMetadata.swift` — envelope shape + `ComfyPayload`.
- `Diffusely/Services/Media/EmbeddedMetadataReader.swift` — keep all fields, sniff container, `metadata(fields:container:)` format detection, EXIF routing, parse-in-read.
- `Diffusely/Views/EmbeddedMetadataView.swift` — switch on format.
- `Diffusely/Views/AppNavigation.swift` — `Route.comfyNodes`.
- `Diffusely/Views/LibraryDetailView.swift` — pass item id + bytes loader to the view; store sniffed container; ⌘C UTType from container.
- `DiffuselyTests/EmbeddedMetadataReaderTests.swift` — update `source` assertions; add format/routing cases.

---

### Task 1: MediaContainer sniffer

**Files:**
- Create: `Diffusely/Services/Media/MediaContainer.swift`
- Test: `DiffuselyTests/MediaContainerTests.swift`

**Interfaces:**
- Produces: `enum MediaContainer: Equatable, Hashable { case png, jpeg, webp, other }`, `static func detect(_ data: Data) -> MediaContainer`, `var fileExtension: String`, `var utType: UTType`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Diffusely

@Suite struct MediaContainerTests {
    @Test func detectsPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        #expect(MediaContainer.detect(png) == .png)
        #expect(MediaContainer.png.fileExtension == "png")
        #expect(MediaContainer.png.utType == .png)
    }

    @Test func detectsJPEG() {
        #expect(MediaContainer.detect(Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 0])) == .jpeg)
        #expect(MediaContainer.jpeg.utType == .jpeg)
    }

    @Test func detectsWebP() {
        var riff = Data("RIFF".utf8)
        riff.append(contentsOf: [0, 0, 0, 0])
        riff.append(Data("WEBP".utf8))
        #expect(MediaContainer.detect(riff) == .webp)
        #expect(MediaContainer.webp.utType == .webP)
    }

    @Test func otherForShortOrUnknownBytes() {
        #expect(MediaContainer.detect(Data()) == .other)
        #expect(MediaContainer.detect(Data([0x00, 0x01, 0x02])) == .other)
        #expect(MediaContainer.detect(Data("RIFF....WAVE".utf8)) == .other)
        #expect(MediaContainer.other.utType == .data)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/MediaContainerTests 2>&1 | tail -25`
Expected: build failure, `cannot find 'MediaContainer' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/MediaContainerTests 2>&1 | tail -25`
Expected: `Test Suite 'MediaContainerTests' passed`, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/MediaContainer.swift DiffuselyTests/MediaContainerTests.swift
git commit -m "feat(media): add MediaContainer magic-byte sniffer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: ComfyGraph model and parser

**Files:**
- Create: `Diffusely/Models/Civitai/ComfyGraph.swift`
- Create: `Diffusely/Services/Media/ComfyGraphParser.swift`
- Test: `DiffuselyTests/ComfyGraphParserTests.swift`

**Interfaces:**
- Produces: `typealias ComfyNodeID = String`; `indirect enum ComfyValue` (`.string`, `.integer(Int64)`, `.unsigned(UInt64)`, `.number(Double)`, `.bool`, `.null`, `.array`, `.object`) with `init(json: Any)` and `var displayText: String`; `enum ComfyInput { case value(ComfyValue); case link(node: ComfyNodeID, slot: Int) }`; `struct ComfyNodeInput { key, value }`; `struct ComfyNode { id, classType, var title, inputs: [ComfyNodeInput] }`; `struct DanglingLink { from, input }`; `struct ComfyGraph { nodes, outputs, danglingLinks }` with `static func make(nodes:) -> ComfyGraph` and `static func numericIDSort(_:_:) -> Bool`; `enum ComfyParseError { malformedJSON, notAGraph, noPromptGraph }`; `ComfyGraphParser.parse(prompt:workflow:) throws -> ComfyGraph`, `decodeLenient(_:) -> Any?`, `cleanBadJSON(_:) -> String`, `makeInput(_:) -> ComfyInput`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct ComfyGraphParserTests {
    private func input(_ node: ComfyNode, _ key: String) -> ComfyInput? {
        node.inputs.first(where: { $0.key == key })?.value
    }

    @Test func linksVersusLiteralArrays() throws {
        let json = #"{"1":{"class_type":"A","inputs":{"x":["2",0],"y":[1,2],"z":["a","b"],"s":"hi","b":true}},"2":{"class_type":"B","inputs":{}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        let a = try #require(g.nodes["1"])
        #expect(input(a, "x") == .link(node: "2", slot: 0))
        #expect(input(a, "y") == .value(.array([.integer(1), .integer(2)])))
        #expect(input(a, "z") == .value(.array([.string("a"), .string("b")])))
        #expect(input(a, "s") == .value(.string("hi")))
        #expect(input(a, "b") == .value(.bool(true)))
        #expect(a.inputs.map(\.key) == ["b", "s", "x", "y", "z"]) // sorted for stable display
    }

    @Test func outputsAreUnconsumedNodes() throws {
        let json = #"{"1":{"class_type":"Save","inputs":{"images":["2",0]}},"2":{"class_type":"Decode","inputs":{}},"3":{"class_type":"Loose","inputs":{}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        #expect(g.outputs == ["1", "3"])
    }

    @Test func danglingLinkRecordedNotThrown() throws {
        let json = #"{"1":{"class_type":"A","inputs":{"x":["99",0]}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        #expect(g.danglingLinks == [DanglingLink(from: "1", input: "x")])
        #expect(input(g.nodes["1"]!, "x") == .link(node: "99", slot: 0))
    }

    @Test func nanIsSanitizedOnlyWhenCleanDecodeFails() throws {
        let bad = #"{"1":{"class_type":"A","inputs":{"v":NaN,"arr":[NaN]}}}"#
        let g = try ComfyGraphParser.parse(prompt: bad, workflow: nil)
        #expect(input(g.nodes["1"]!, "v") == .value(.integer(0)))
        #expect(input(g.nodes["1"]!, "arr") == .value(.array([])))

        // Valid JSON containing the word NaN inside a string is left alone.
        let fine = #"{"1":{"class_type":"A","inputs":{"text":"NaN and Infinity"}}}"#
        let g2 = try ComfyGraphParser.parse(prompt: fine, workflow: nil)
        #expect(input(g2.nodes["1"]!, "text") == .value(.string("NaN and Infinity")))
    }

    @Test func bigSeedsKeepPrecision() throws {
        let json = #"{"1":{"class_type":"A","inputs":{"seed":18446744073709551615,"neg":-3,"small":42}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        #expect(input(g.nodes["1"]!, "seed") == .value(.unsigned(18446744073709551615)))
        #expect(input(g.nodes["1"]!, "neg") == .value(.integer(-3)))
        #expect(input(g.nodes["1"]!, "small") == .value(.integer(42)))
        #expect(ComfyValue.unsigned(18446744073709551615).displayText == "18446744073709551615")
    }

    @Test func workflowTitlesEnrichNodes() throws {
        let prompt = #"{"1":{"class_type":"A","inputs":{}},"2":{"class_type":"B","inputs":{},"_meta":{"title":"From prompt"}}}"#
        let workflow = #"{"nodes":[{"id":1,"type":"A","title":"Fancy A"},{"id":2,"type":"B","title":"Ignored"}]}"#
        let g = try ComfyGraphParser.parse(prompt: prompt, workflow: workflow)
        #expect(g.nodes["1"]?.title == "Fancy A")
        #expect(g.nodes["2"]?.title == "From prompt") // _meta.title wins
    }

    @Test func unparseableWorkflowDoesNotFailGraph() throws {
        let prompt = #"{"1":{"class_type":"A","inputs":{}}}"#
        let g = try ComfyGraphParser.parse(prompt: prompt, workflow: "{{not json")
        #expect(g.nodes.count == 1)
        #expect(g.nodes["1"]?.title == nil)
    }

    @Test func notAGraphWhenNoClassType() {
        #expect(throws: ComfyParseError.notAGraph) {
            try ComfyGraphParser.parse(prompt: #"{"a":1,"b":{"x":2}}"#, workflow: nil)
        }
        #expect(throws: ComfyParseError.notAGraph) {
            try ComfyGraphParser.parse(prompt: #"[1,2,3]"#, workflow: nil)
        }
    }

    @Test func malformedJSONThrows() {
        #expect(throws: ComfyParseError.malformedJSON) {
            try ComfyGraphParser.parse(prompt: "not json at all", workflow: nil)
        }
    }

    @Test func numericIDSortOrdersNumbersThenStrings() {
        let ids = ["10", "2", "b", "a", "1"]
        #expect(ids.sorted(by: ComfyGraph.numericIDSort) == ["1", "2", "10", "a", "b"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyGraphParserTests 2>&1 | tail -25`
Expected: build failure, `cannot find 'ComfyGraphParser' in scope`.

- [ ] **Step 3: Write the model**

`Diffusely/Models/Civitai/ComfyGraph.swift`:

```swift
import Foundation

/// ComfyUI node ids are the string keys of the API-format `prompt` dict ("3", "12", …).
typealias ComfyNodeID = String

/// A JSON value as it appears in a node's `inputs`. Integers keep full 64-bit
/// precision: seeds are uint64 and about half of random ones exceed Int64.max.
indirect enum ComfyValue: Equatable, Hashable {
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)   // only for values above Int64.max
    case number(Double)
    case bool(Bool)
    case null
    case array([ComfyValue])
    case object([String: ComfyValue])

    /// Builds from a `JSONSerialization` object. Bool must be checked before the
    /// numeric branches: `true` arrives as an NSNumber whose objCType is "c".
    init(json: Any) {
        switch json {
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            let objCType = String(cString: n.objCType)
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if objCType == "Q" {
                self = n.uint64Value > UInt64(Int64.max) ? .unsigned(n.uint64Value) : .integer(n.int64Value)
            } else if "csilqCSIL".contains(objCType) {
                self = .integer(n.int64Value)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            self = .array(a.map { ComfyValue(json: $0) })
        case let o as [String: Any]:
            self = .object(o.mapValues { ComfyValue(json: $0) })
        case is NSNull:
            self = .null
        default:
            self = .string(String(describing: json))
        }
    }

    /// Human-readable rendering for the inspector and its search.
    var displayText: String {
        switch self {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .unsigned(let u): return String(u)
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map(\.displayText).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\($0): \(o[$0]!.displayText)" }.joined(separator: ", ") + "}"
        }
    }
}

/// An input slot's content: a literal widget value, or a link to another node's output.
enum ComfyInput: Equatable, Hashable {
    case value(ComfyValue)
    case link(node: ComfyNodeID, slot: Int)
}

struct ComfyNodeInput: Equatable, Hashable {
    let key: String
    let value: ComfyInput
}

struct ComfyNode: Equatable, Hashable {
    let id: ComfyNodeID
    let classType: String
    /// `_meta.title` from the prompt, else the `workflow` chunk's title, else nil.
    var title: String?
    /// Sorted by key so display order is stable across runs.
    let inputs: [ComfyNodeInput]
}

/// A link whose target node id does not exist in the graph.
struct DanglingLink: Equatable, Hashable {
    let from: ComfyNodeID
    let input: String
}

struct ComfyGraph: Equatable, Hashable {
    let nodes: [ComfyNodeID: ComfyNode]
    /// Nodes no other node links to. Usually one SaveImage; may be several.
    let outputs: [ComfyNodeID]
    let danglingLinks: [DanglingLink]

    /// Assembles a graph from nodes, deriving `outputs` and `danglingLinks`.
    static func make(nodes: [ComfyNodeID: ComfyNode]) -> ComfyGraph {
        var targets = Set<ComfyNodeID>()
        var dangling: [DanglingLink] = []
        for node in nodes.values.sorted(by: { numericIDSort($0.id, $1.id) }) {
            for input in node.inputs {
                guard case .link(let target, _) = input.value else { continue }
                if nodes[target] == nil {
                    dangling.append(DanglingLink(from: node.id, input: input.key))
                } else {
                    targets.insert(target)
                }
            }
        }
        let outputs = nodes.keys.filter { !targets.contains($0) }.sorted(by: numericIDSort)
        return ComfyGraph(nodes: nodes, outputs: outputs, danglingLinks: dangling)
    }

    /// Numeric ids in numeric order first, then any non-numeric ids lexically.
    static func numericIDSort(_ a: ComfyNodeID, _ b: ComfyNodeID) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x != y ? x < y : a < b
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a < b
        }
    }
}
```

- [ ] **Step 4: Write the parser**

`Diffusely/Services/Media/ComfyGraphParser.swift`:

```swift
import Foundation

enum ComfyParseError: Error, Equatable {
    case malformedJSON
    /// Parsed, but nothing in it carries `class_type`.
    case notAGraph
    /// Only a `workflow` (UI) chunk was present; there is no API graph to walk.
    case noPromptGraph
}

/// Turns ComfyUI's API-format `prompt` JSON into a typed `ComfyGraph`. Knows
/// nothing about what any node class means — that is `ComfyRecipeBuilder`.
enum ComfyGraphParser {
    static func parse(prompt: String, workflow: String?) throws -> ComfyGraph {
        guard let any = decodeLenient(prompt) else { throw ComfyParseError.malformedJSON }
        guard let root = any as? [String: Any] else { throw ComfyParseError.notAGraph }

        var nodes: [ComfyNodeID: ComfyNode] = [:]
        for (id, value) in root {
            guard let dict = value as? [String: Any],
                  let classType = dict["class_type"] as? String else { continue }
            let rawInputs = dict["inputs"] as? [String: Any] ?? [:]
            let inputs = rawInputs.keys.sorted().map {
                ComfyNodeInput(key: $0, value: makeInput(rawInputs[$0]!))
            }
            let title = (dict["_meta"] as? [String: Any])?["title"] as? String
            nodes[id] = ComfyNode(id: id, classType: classType, title: title, inputs: inputs)
        }
        guard !nodes.isEmpty else { throw ComfyParseError.notAGraph }

        applyWorkflowTitles(workflow, to: &nodes)
        return ComfyGraph.make(nodes: nodes)
    }

    /// Decodes JSON, retrying once through `cleanBadJSON` if the first attempt
    /// fails. Well-formed input is never rewritten.
    static func decodeLenient(_ text: String) -> Any? {
        if let any = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
            return any
        }
        return try? JSONSerialization.jsonObject(with: Data(cleanBadJSON(text).utf8), options: [.fragmentsAllowed])
    }

    /// ComfyUI writes `NaN` / `Infinity`, which JSON forbids. Port of Civitai's
    /// `cleanBadJson` (src/utils/metadata/comfy.metadata.ts).
    static func cleanBadJSON(_ text: String) -> String {
        text.replacingOccurrences(of: "[NaN]", with: "[]")
            .replacingOccurrences(of: "\\bNaN\\b", with: "0", options: .regularExpression)
            .replacingOccurrences(of: "[Infinity]", with: "[]")
    }

    /// `["12", 0]` is a link (string id, numeric slot); every other shape is a literal.
    static func makeInput(_ any: Any) -> ComfyInput {
        if let pair = any as? [Any], pair.count == 2,
           let id = pair[0] as? String,
           let slot = pair[1] as? NSNumber,
           CFGetTypeID(slot) != CFBooleanGetTypeID() {
            return .link(node: id, slot: slot.intValue)
        }
        return .value(ComfyValue(json: any))
    }

    /// Copies litegraph `title`s onto nodes that have no `_meta.title`. Best-effort:
    /// an unparseable `workflow` leaves the graph untouched.
    private static func applyWorkflowTitles(_ workflow: String?, to nodes: inout [ComfyNodeID: ComfyNode]) {
        guard let workflow,
              let wf = decodeLenient(workflow) as? [String: Any],
              let wfNodes = wf["nodes"] as? [[String: Any]] else { return }
        for entry in wfNodes {
            let id: ComfyNodeID?
            if let n = entry["id"] as? NSNumber { id = String(n.int64Value) } else { id = entry["id"] as? String }
            guard let id, var node = nodes[id], node.title == nil,
                  let title = entry["title"] as? String, !title.isEmpty else { continue }
            node.title = title
            nodes[id] = node
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyGraphParserTests 2>&1 | tail -25`
Expected: `Test Suite 'ComfyGraphParserTests' passed`, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Models/Civitai/ComfyGraph.swift Diffusely/Services/Media/ComfyGraphParser.swift DiffuselyTests/ComfyGraphParserTests.swift
git commit -m "feat(comfy): typed ComfyUI graph model and lenient prompt parser

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: ComfySchema table and ComfyRecipe types

**Files:**
- Create: `Diffusely/Services/Media/ComfySchema.swift`
- Create: `Diffusely/Models/Civitai/ComfyRecipe.swift`

**Interfaces:**
- Produces: `enum ComfyRole { case model, conditioning, latent }`; `enum ComfySchema` static sets (`samplerAnchors`, `baseLoaders`, `loraLoaders`, `modelModifiers`, `textEncoders`, `textWidgetKeys`, `conditioningCombiners`, `conditioningPassThrough`, `controlNetAppliers`, `guidanceModifiers`, `emptyLatents`, `latentUpscalers`, `pixelUpscalers`, `vaeEncoders`, `vaeDecoders`, `imageLoaders`, `vaeLoaders`, `upscaleModelLoaders`, `baseNameKeys`, `resourceNameWidgetKeys`, `passThroughInputs`, `linkResolutionDepth`, `walkDepthCap`); the recipe value types listed in the spec's Section 3.

No test of its own — these are data and plain structs; Task 4's tests exercise them.

- [ ] **Step 1: Write the schema**

`Diffusely/Services/Media/ComfySchema.swift`:

```swift
import Foundation

/// Which of a node's inputs the builder is currently following.
enum ComfyRole {
    case model, conditioning, latent
}

/// Every node-class name `ComfyRecipeBuilder` recognizes, in one place so a new
/// node type is a one-line addition. Anything not listed here is passed through
/// on its role-matching input and reported as "unrecognized".
enum ComfySchema {
    static let samplerAnchors: Set<String> = [
        "KSampler", "KSamplerAdvanced", "SamplerCustom", "SamplerCustomAdvanced",
    ]
    static let baseLoaders: Set<String> = [
        "CheckpointLoaderSimple", "CheckpointLoader", "UNETLoader", "UnetLoaderGGUF",
        "ImageOnlyCheckpointLoader", "unCLIPCheckpointLoader", "DiffusersLoader",
        "CheckpointLoaderNF4", "UNETLoaderNF4",
    ]
    /// Widget keys, in preference order, that name a base model on a loader.
    static let baseNameKeys = ["ckpt_name", "unet_name", "model_name"]
    static let loraLoaders: Set<String> = ["LoraLoader", "LoraLoaderModelOnly"]
    static let modelModifiers: Set<String> = [
        "ModelSamplingFlux", "ModelSamplingSD3", "ModelSamplingDiscrete",
        "ModelSamplingContinuousEDM", "ModelSamplingAuraFlow", "FreeU", "FreeU_V2",
        "PatchModelAddDownscale", "PerturbedAttentionGuidance", "RescaleCFG",
        "TomePatchModel", "SelfAttentionGuidance", "CFGNorm",
    ]
    static let textEncoders: Set<String> = [
        "CLIPTextEncode", "CLIPTextEncodeSDXL", "CLIPTextEncodeSDXLRefiner",
        "CLIPTextEncodeFlux", "CLIPTextEncodeSD3", "CLIPTextEncodeHunyuanDiT",
    ]
    /// Widget keys, in order, that can hold prompt text on an encoder.
    static let textWidgetKeys = ["text", "text_g", "text_l", "clip_l", "t5xxl", "clip_g"]
    static let conditioningCombiners: Set<String> = [
        "ConditioningCombine", "ConditioningConcat", "ConditioningAverage",
    ]
    /// One-in, one-out conditioning tweaks: followed on `conditioning`, noted as modifiers.
    static let conditioningPassThrough: Set<String> = [
        "ConditioningSetTimestepRange", "ConditioningSetArea", "ConditioningSetAreaPercentage",
        "ConditioningSetAreaStrength", "ConditioningSetMask", "ConditioningZeroOut",
    ]
    static let controlNetAppliers: Set<String> = [
        "ControlNetApply", "ControlNetApplyAdvanced", "ControlNetApplySD3",
    ]
    static let guidanceModifiers: Set<String> = ["FluxGuidance"]
    static let emptyLatents: Set<String> = [
        "EmptyLatentImage", "EmptySD3LatentImage", "EmptyHunyuanLatentVideo",
        "EmptyLTXVLatentVideo", "EmptyMochiLatentVideo", "EmptyCosmosLatentVideo",
    ]
    static let latentUpscalers: Set<String> = ["LatentUpscale", "LatentUpscaleBy"]
    static let pixelUpscalers: Set<String> = ["ImageUpscaleWithModel", "ImageScale", "ImageScaleBy"]
    static let vaeEncoders: Set<String> = ["VAEEncode", "VAEEncodeTiled", "VAEEncodeForInpaint"]
    static let vaeDecoders: Set<String> = ["VAEDecode", "VAEDecodeTiled"]
    static let imageLoaders: Set<String> = ["LoadImage", "LoadImageMask"]
    static let vaeLoaders: Set<String> = ["VAELoader"]
    static let upscaleModelLoaders: Set<String> = ["UpscaleModelLoader"]

    /// Widget keys tried, after the requested key, when a widget value is a link
    /// to a primitive/string node.
    static let resourceNameWidgetKeys = ["value", "string", "text"]
    /// Input names followed when passing through an unrecognized node, per role.
    /// Conditioning is special-cased by the builder (positive vs negative).
    static let passThroughInputs: [ComfyRole: [String]] = [
        .model: ["model"],
        .conditioning: ["conditioning", "positive", "negative"],
        .latent: ["latent", "latent_image", "samples", "pixels", "image", "images"],
    ]
    static let linkResolutionDepth = 5
    static let walkDepthCap = 500
}
```

- [ ] **Step 2: Write the recipe types**

`Diffusely/Models/Civitai/ComfyRecipe.swift`:

```swift
import Foundation

/// The structural summary of a ComfyUI graph: an ordered list of sampling passes
/// plus the resources they used. Built by `ComfyRecipeBuilder`; view-only.
struct ComfyRecipe: Equatable, Hashable {
    let passes: [SamplingPass]           // execution order
    let resources: ResourceSummary       // union across passes, de-duplicated by name
    let unattributed: [ComfyNodeID]      // never reached by any walk
}

struct SamplingPass: Equatable, Hashable {
    let anchor: ComfyNodeID              // the sampler node
    let anchorClass: String
    let sampler: SamplerSettings
    let modelChain: [ModelStep]          // base first, then LoRAs in apply order
    let positive: [ConditioningText]     // several if combined/concatenated
    let negative: [ConditioningText]
    let latentSource: LatentSource
    let modifiers: [String]              // recognized pass-through classes seen
    let unrecognized: [ComfyNodeID]      // passed through blind on this pass
    let nodeIDs: Set<ComfyNodeID>        // everything attributed here (inspector)
}

struct SamplerSettings: Equatable, Hashable {
    var seed: UInt64? = nil
    var steps: Int? = nil
    var cfg: Double? = nil
    var samplerName: String? = nil
    var scheduler: String? = nil
    var denoise: Double? = nil
    var startStep: Int? = nil
    var endStep: Int? = nil
}

enum ModelStep: Equatable, Hashable {
    case base(name: String?, classType: String)
    case lora(name: String, strengthModel: Double?, strengthClip: Double?)
}

struct ConditioningText: Equatable, Hashable {
    let text: String
    let nodeID: ComfyNodeID
}

enum LatentSource: Equatable, Hashable {
    case empty(width: Int?, height: Int?, batch: Int?)
    case fromPass(ComfyNodeID, via: [String])            // e.g. ["LatentUpscaleBy"]
    case image(loadNode: ComfyNodeID, name: String?, via: [String])
    case unknown
}

struct LoraResource: Equatable, Hashable {
    let name: String
    let strength: Double?                // max strengthModel seen across passes
}

struct ResourceSummary: Equatable, Hashable {
    let baseModels: [String]
    let loras: [LoraResource]
    let vaes: [String]
    let controlNets: [String]
    let upscaleModels: [String]
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Services/Media/ComfySchema.swift Diffusely/Models/Civitai/ComfyRecipe.swift
git commit -m "feat(comfy): node-class schema table and recipe value types

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Recipe builder — single pass, model chain, attribution

**Files:**
- Create: `Diffusely/Services/Media/ComfyRecipeBuilder.swift`
- Test: `DiffuselyTests/ComfyRecipeBuilderTests.swift`

**Interfaces:**
- Consumes: `ComfyGraph`, `ComfySchema`, recipe types from Task 3.
- Produces: `ComfyRecipeBuilder.build(_ graph: ComfyGraph) -> ComfyRecipe`. Internal `Builder` struct with `walkFromOutput`, `extractPassIfNeeded`, `walkModel`, `walkConditioning`, `walkLatent`, `resolveWidget`, `orderedPasses`, `resourceSummary` — Tasks 5–7 replace some of these whole.

- [ ] **Step 1: Write the failing tests (with the shared graph DSL)**

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct ComfyRecipeBuilderTests {
    // MARK: - DSL

    static func node(_ id: String, _ cls: String, _ inputs: [String: ComfyInput] = [:]) -> ComfyNode {
        ComfyNode(id: id, classType: cls, title: nil,
                  inputs: inputs.keys.sorted().map { ComfyNodeInput(key: $0, value: inputs[$0]!) })
    }
    /// Last definition of an id wins, so a test can override a node from `txt2img` via `extra:`.
    static func graph(_ nodes: [ComfyNode]) -> ComfyGraph {
        ComfyGraph.make(nodes: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }))
    }
    static func link(_ id: String, _ slot: Int = 0) -> ComfyInput { .link(node: id, slot: slot) }
    static func str(_ s: String) -> ComfyInput { .value(.string(s)) }
    static func int(_ i: Int64) -> ComfyInput { .value(.integer(i)) }
    static func num(_ d: Double) -> ComfyInput { .value(.number(d)) }

    /// Checkpoint(4) → CLIPTextEncode(6,7) → KSampler(3) ← EmptyLatent(5); VAEDecode(8) → SaveImage(9).
    /// `samplerModel` lets a test splice LoRAs between the checkpoint and the sampler.
    static func txt2img(samplerModel: String = "4", extra: [ComfyNode] = []) -> ComfyGraph {
        graph([
            node("4", "CheckpointLoaderSimple", ["ckpt_name": str("sdxl_base.safetensors")]),
            node("5", "EmptyLatentImage", ["width": int(1024), "height": int(1024), "batch_size": int(1)]),
            node("6", "CLIPTextEncode", ["text": str("a cat"), "clip": link("4", 1)]),
            node("7", "CLIPTextEncode", ["text": str("blurry"), "clip": link("4", 1)]),
            node("3", "KSampler", ["model": link(samplerModel), "positive": link("6"), "negative": link("7"),
                                   "latent_image": link("5"), "seed": int(42), "steps": int(20), "cfg": num(7),
                                   "sampler_name": str("euler"), "scheduler": str("normal"), "denoise": num(1)]),
            node("8", "VAEDecode", ["samples": link("3"), "vae": link("4", 2)]),
            node("9", "SaveImage", ["images": link("8"), "filename_prefix": str("out")]),
        ] + extra)
    }

    // MARK: - Task 4

    @Test func singlePassTxt2img() {
        let recipe = ComfyRecipeBuilder.build(Self.txt2img())
        #expect(recipe.passes.count == 1)
        let pass = recipe.passes[0]
        #expect(pass.anchor == "3")
        #expect(pass.anchorClass == "KSampler")
        #expect(pass.sampler == SamplerSettings(seed: 42, steps: 20, cfg: 7, samplerName: "euler",
                                                scheduler: "normal", denoise: 1))
        #expect(pass.modelChain == [.base(name: "sdxl_base.safetensors", classType: "CheckpointLoaderSimple")])
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.negative == [ConditioningText(text: "blurry", nodeID: "7")])
        #expect(pass.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(pass.modifiers.isEmpty)
        #expect(pass.unrecognized.isEmpty)
        #expect(recipe.resources.baseModels == ["sdxl_base.safetensors"])
        #expect(recipe.unattributed.isEmpty)
    }

    @Test func loraChainInApplyOrderWithStrengths() {
        let g = Self.txt2img(samplerModel: "11", extra: [
            Self.node("10", "LoraLoader", ["model": Self.link("4"), "clip": Self.link("4", 1),
                                           "lora_name": Self.str("detail.safetensors"),
                                           "strength_model": Self.num(0.8), "strength_clip": Self.num(0.8)]),
            Self.node("11", "LoraLoaderModelOnly", ["model": Self.link("10"),
                                                    "lora_name": Self.str("style.safetensors"),
                                                    "strength_model": Self.num(0.6)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [
            .base(name: "sdxl_base.safetensors", classType: "CheckpointLoaderSimple"),
            .lora(name: "detail.safetensors", strengthModel: 0.8, strengthClip: 0.8),
            .lora(name: "style.safetensors", strengthModel: 0.6, strengthClip: nil),
        ])
        #expect(ComfyRecipeBuilder.build(g).resources.loras == [
            LoraResource(name: "detail.safetensors", strength: 0.8),
            LoraResource(name: "style.safetensors", strength: 0.6),
        ])
        #expect(pass.nodeIDs.isSuperset(of: ["10", "11"]))
    }

    @Test func outputPlumbingAndVAEAttributedToPass() {
        let g = Self.txt2img(extra: [
            Self.node("12", "VAELoader", ["vae_name": Self.str("ae.safetensors")]),
            // Rewire VAEDecode's vae to the standalone loader.
            Self.node("8", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("12")]),
            Self.node("99", "Note", ["text": Self.str("disconnected")]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        let pass = recipe.passes[0]
        #expect(pass.nodeIDs.isSuperset(of: ["9", "8", "12", "3", "4", "5", "6", "7"]))
        #expect(recipe.resources.vaes == ["ae.safetensors"])
        #expect(recipe.unattributed == ["99"])
    }

    @Test func widgetLinksResolveThroughPrimitives() {
        let g = Self.graph([
            Self.node("4", "CheckpointLoaderSimple", ["ckpt_name": Self.str("m.safetensors")]),
            Self.node("5", "EmptyLatentImage", ["width": Self.int(512), "height": Self.int(512), "batch_size": Self.int(1)]),
            Self.node("20", "Seed Generator", ["seed": Self.int(7)]),
            Self.node("21", "String Literal", ["string": Self.str("from primitive")]),
            Self.node("6", "CLIPTextEncode", ["text": Self.link("21"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncode", ["text": Self.str("neg"), "clip": Self.link("4", 1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.link("20"), "steps": Self.int(10),
                                        "cfg": Self.num(5), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"),
                                        "denoise": Self.num(1)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("4", 2)]),
            Self.node("9", "SaveImage", ["images": Self.link("8")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.sampler.seed == 7)
        #expect(pass.positive == [ConditioningText(text: "from primitive", nodeID: "6")])
        #expect(pass.nodeIDs.isSuperset(of: ["20", "21"]))
    }

    @Test func widgetLinkDepthIsCapped() {
        // seed → p1 → p2 → … → p7 → literal. Seven hops exceed the cap of five.
        var nodes: [ComfyNode] = [
            Self.node("4", "CheckpointLoaderSimple", ["ckpt_name": Self.str("m")]),
            Self.node("5", "EmptyLatentImage", ["width": Self.int(8), "height": Self.int(8), "batch_size": Self.int(1)]),
            Self.node("6", "CLIPTextEncode", ["text": Self.str("p"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncode", ["text": Self.str("n"), "clip": Self.link("4", 1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.link("p1"), "steps": Self.int(1),
                                        "cfg": Self.num(1), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"),
                                        "denoise": Self.num(1)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("4", 2)]),
            Self.node("9", "SaveImage", ["images": Self.link("8")]),
        ]
        for i in 1...6 { nodes.append(Self.node("p\(i)", "Relay", ["value": Self.link("p\(i + 1)")])) }
        nodes.append(Self.node("p7", "Relay", ["value": Self.int(5)]))
        let pass = ComfyRecipeBuilder.build(Self.graph(nodes)).passes[0]
        #expect(pass.sampler.seed == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: build failure, `cannot find 'ComfyRecipeBuilder' in scope`.

- [ ] **Step 3: Write the builder**

`Diffusely/Services/Media/ComfyRecipeBuilder.swift` (this is the complete file for Task 4; Tasks 5–7 replace individual functions):

```swift
import Foundation

/// Derives a `ComfyRecipe` from a `ComfyGraph` by walking backwards from each
/// output. Pure and deterministic. The only code that knows what a node class
/// *means*; the class names themselves live in `ComfySchema`.
enum ComfyRecipeBuilder {
    static func build(_ graph: ComfyGraph) -> ComfyRecipe {
        var builder = Builder(graph: graph)
        for output in graph.outputs { builder.walkFromOutput(output) }
        let passes = builder.orderedPasses()
        let attributed = passes.reduce(into: Set<ComfyNodeID>()) { $0.formUnion($1.nodeIDs) }
        let unattributed = graph.nodes.keys
            .filter { !attributed.contains($0) }
            .sorted(by: ComfyGraph.numericIDSort)
        return ComfyRecipe(passes: passes,
                           resources: builder.resourceSummary(passes),
                           unattributed: unattributed)
    }

    /// Mutable per-pass accumulator; becomes a `SamplingPass` at the end.
    struct PassDraft {
        let anchor: ComfyNodeID
        let anchorClass: String
        var sampler = SamplerSettings()
        var modelChain: [ModelStep] = []
        var positive: [ConditioningText] = []
        var negative: [ConditioningText] = []
        var latentSource: LatentSource = .unknown
        var modifiers: [String] = []
        var unrecognized: [ComfyNodeID] = []
        var nodeIDs: Set<ComfyNodeID> = []

        var pass: SamplingPass {
            SamplingPass(anchor: anchor, anchorClass: anchorClass, sampler: sampler,
                         modelChain: modelChain, positive: positive, negative: negative,
                         latentSource: latentSource, modifiers: modifiers,
                         unrecognized: unrecognized, nodeIDs: nodeIDs)
        }

        mutating func noteUnrecognized(_ id: ComfyNodeID) {
            if !unrecognized.contains(id) { unrecognized.append(id) }
        }
    }

    struct Builder {
        let graph: ComfyGraph
        var drafts: [ComfyNodeID: PassDraft] = [:]
        /// Anchors whose extraction is underway — guards a malformed graph where
        /// two samplers feed each other's latent.
        var inProgress: Set<ComfyNodeID> = []
        var vaes: [String] = []
        var upscaleModels: [String] = []
        var controlNets: [String] = []

        // MARK: Output plumbing

        /// Walks every link backwards from an output until the first sampler
        /// anchor. Everything before an anchor (SaveImage, VAEDecode, the VAE
        /// loader, pixel upscalers…) is attributed to that anchor's pass.
        mutating func walkFromOutput(_ outputID: ComfyNodeID) {
            var plumbing: [ComfyNodeID] = []
            var anchors: [ComfyNodeID] = []
            var stack = [outputID]
            var seen = Set<ComfyNodeID>()
            while let id = stack.popLast() {
                guard seen.insert(id).inserted, let node = graph.nodes[id] else { continue }
                if ComfySchema.samplerAnchors.contains(node.classType) {
                    anchors.append(id)
                    continue
                }
                plumbing.append(id)
                recordPlumbingResource(node)
                for input in node.inputs {
                    if case .link(let target, _) = input.value { stack.append(target) }
                }
            }
            for anchor in anchors {
                extractPassIfNeeded(anchor)
                drafts[anchor]?.nodeIDs.formUnion(plumbing)
            }
        }

        mutating func recordPlumbingResource(_ node: ComfyNode) {
            if ComfySchema.vaeLoaders.contains(node.classType),
               let name = literalString(node, "vae_name"), !vaes.contains(name) {
                vaes.append(name)
            }
            if ComfySchema.upscaleModelLoaders.contains(node.classType),
               let name = literalString(node, "model_name"), !upscaleModels.contains(name) {
                upscaleModels.append(name)
            }
        }

        // MARK: Pass extraction

        mutating func extractPassIfNeeded(_ anchor: ComfyNodeID) {
            guard drafts[anchor] == nil, !inProgress.contains(anchor),
                  let node = graph.nodes[anchor] else { return }
            inProgress.insert(anchor)
            defer { inProgress.remove(anchor) }

            var draft = PassDraft(anchor: anchor, anchorClass: node.classType)
            draft.nodeIDs.insert(anchor)
            readSamplerSettings(node, into: &draft)

            if let start = modelStart(node, into: &draft) {
                walkModel(from: start, into: &draft)
            }
            let starts = conditioningStarts(node, into: &draft)
            if let pos = starts.positive {
                draft.positive = walkConditioning(from: pos, negative: false, into: &draft)
            }
            if let neg = starts.negative {
                draft.negative = walkConditioning(from: neg, negative: true, into: &draft)
            }
            if let latent = linkTarget(node, "latent_image") ?? linkTarget(node, "latent") {
                draft.latentSource = walkLatent(from: latent, into: &draft)
            }
            drafts[anchor] = draft
        }

        mutating func readSamplerSettings(_ node: ComfyNode, into draft: inout PassDraft) {
            switch node.classType {
            case "KSampler":
                draft.sampler.seed = seedWidget(node, "seed", &draft)
                draft.sampler.steps = intWidget(node, "steps", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                draft.sampler.samplerName = stringWidget(node, "sampler_name", &draft)
                draft.sampler.scheduler = stringWidget(node, "scheduler", &draft)
                draft.sampler.denoise = doubleWidget(node, "denoise", &draft)
            default:
                break
            }
        }

        mutating func modelStart(_ node: ComfyNode, into draft: inout PassDraft) -> ComfyNodeID? {
            linkTarget(node, "model")
        }

        mutating func conditioningStarts(_ node: ComfyNode, into draft: inout PassDraft)
            -> (positive: ComfyNodeID?, negative: ComfyNodeID?) {
            (linkTarget(node, "positive"), linkTarget(node, "negative"))
        }

        // MARK: Model chain

        mutating func walkModel(from start: ComfyNodeID, into draft: inout PassDraft) {
            var current: ComfyNodeID? = start
            var loras: [ModelStep] = []
            var base: ModelStep?
            var depth = 0
            var seen = Set<ComfyNodeID>()
            while let id = current, depth < ComfySchema.walkDepthCap, seen.insert(id).inserted {
                depth += 1
                guard let node = graph.nodes[id] else { break }
                draft.nodeIDs.insert(id)
                let cls = node.classType
                if ComfySchema.baseLoaders.contains(cls) {
                    base = .base(name: baseName(node, &draft), classType: cls)
                    break
                } else if ComfySchema.loraLoaders.contains(cls) {
                    loras.append(.lora(name: stringWidget(node, "lora_name", &draft) ?? "?",
                                       strengthModel: doubleWidget(node, "strength_model", &draft),
                                       strengthClip: doubleWidget(node, "strength_clip", &draft)))
                    current = linkTarget(node, "model")
                } else if ComfySchema.modelModifiers.contains(cls) {
                    draft.modifiers.append(cls)
                    current = linkTarget(node, "model")
                } else {
                    draft.noteUnrecognized(id)
                    base = .base(name: nil, classType: cls)
                    break
                }
            }
            // Walking backwards visits the last-applied LoRA first; store apply order.
            draft.modelChain = [base ?? .base(name: nil, classType: "unknown")] + loras.reversed()
        }

        func baseName(_ node: ComfyNode, _ draft: inout PassDraft) -> String? {
            for key in ComfySchema.baseNameKeys {
                if let name = stringWidget(node, key, &draft) { return name }
            }
            return nil
        }

        // MARK: Conditioning

        mutating func walkConditioning(from start: ComfyNodeID, negative: Bool,
                                       into draft: inout PassDraft, depth: Int = 0) -> [ConditioningText] {
            guard depth < ComfySchema.walkDepthCap, let node = graph.nodes[start] else { return [] }
            draft.nodeIDs.insert(start)
            if ComfySchema.textEncoders.contains(node.classType) {
                return [ConditioningText(text: encodedText(node, &draft), nodeID: start)]
            }
            draft.noteUnrecognized(start)
            return []
        }

        /// Joins every distinct non-empty text widget on an encoder (SDXL encoders
        /// carry `text_g`/`text_l`, Flux `clip_l`/`t5xxl`).
        func encodedText(_ node: ComfyNode, _ draft: inout PassDraft) -> String {
            var texts: [String] = []
            for key in ComfySchema.textWidgetKeys {
                if let t = stringWidget(node, key, &draft),
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !texts.contains(t) {
                    texts.append(t)
                }
            }
            return texts.joined(separator: "\n")
        }

        // MARK: Latent

        mutating func walkLatent(from start: ComfyNodeID, into draft: inout PassDraft) -> LatentSource {
            guard let node = graph.nodes[start] else { return .unknown }
            draft.nodeIDs.insert(start)
            if ComfySchema.emptyLatents.contains(node.classType) {
                return .empty(width: intWidget(node, "width", &draft),
                              height: intWidget(node, "height", &draft),
                              batch: intWidget(node, "batch_size", &draft))
            }
            draft.noteUnrecognized(start)
            return .unknown
        }

        // MARK: Ordering and resources

        func orderedPasses() -> [SamplingPass] {
            drafts.keys.sorted(by: ComfyGraph.numericIDSort).map { drafts[$0]!.pass }
        }

        func resourceSummary(_ passes: [SamplingPass]) -> ResourceSummary {
            var bases: [String] = []
            var loraNames: [String] = []
            var loraStrength: [String: Double] = [:]
            for pass in passes {
                for step in pass.modelChain {
                    switch step {
                    case .base(let name?, _):
                        if !bases.contains(name) { bases.append(name) }
                    case .base:
                        break
                    case .lora(let name, let strength, _):
                        if !loraNames.contains(name) { loraNames.append(name) }
                        if let strength, strength > (loraStrength[name] ?? -.infinity) {
                            loraStrength[name] = strength
                        }
                    }
                }
            }
            return ResourceSummary(baseModels: bases,
                                   loras: loraNames.map { LoraResource(name: $0, strength: loraStrength[$0]) },
                                   vaes: vaes, controlNets: controlNets, upscaleModels: upscaleModels)
        }

        // MARK: Widget access

        func linkTarget(_ node: ComfyNode, _ key: String) -> ComfyNodeID? {
            guard let input = node.inputs.first(where: { $0.key == key }),
                  case .link(let target, _) = input.value else { return nil }
            return target
        }

        func literalString(_ node: ComfyNode, _ key: String) -> String? {
            guard let input = node.inputs.first(where: { $0.key == key }),
                  case .value(.string(let s)) = input.value else { return nil }
            return s
        }

        /// A widget's value, following links to primitive/string nodes up to
        /// `ComfySchema.linkResolutionDepth` hops. Visited primitives join the pass.
        func resolveWidget(_ node: ComfyNode, _ key: String, _ draft: inout PassDraft, depth: Int = 0) -> ComfyValue? {
            guard let input = node.inputs.first(where: { $0.key == key }) else { return nil }
            switch input.value {
            case .value(let v):
                return v
            case .link(let target, _):
                guard depth < ComfySchema.linkResolutionDepth, let source = graph.nodes[target] else { return nil }
                draft.nodeIDs.insert(target)
                for k in [key] + ComfySchema.resourceNameWidgetKeys {
                    if let v = resolveWidget(source, k, &draft, depth: depth + 1) { return v }
                }
                return nil
            }
        }

        func stringWidget(_ node: ComfyNode, _ key: String, _ draft: inout PassDraft) -> String? {
            if case .string(let s)? = resolveWidget(node, key, &draft) { return s }
            return nil
        }

        func doubleWidget(_ node: ComfyNode, _ key: String, _ draft: inout PassDraft) -> Double? {
            switch resolveWidget(node, key, &draft) {
            case .number(let d)?: return d
            case .integer(let i)?: return Double(i)
            case .unsigned(let u)?: return Double(u)
            default: return nil
            }
        }

        func intWidget(_ node: ComfyNode, _ key: String, _ draft: inout PassDraft) -> Int? {
            switch resolveWidget(node, key, &draft) {
            case .integer(let i)?: return Int(exactly: i)
            case .unsigned(let u)?: return Int(exactly: u)
            case .number(let d)?: return Int(exactly: d)
            default: return nil
            }
        }

        func seedWidget(_ node: ComfyNode, _ key: String, _ draft: inout PassDraft) -> UInt64? {
            switch resolveWidget(node, key, &draft) {
            case .unsigned(let u)?: return u
            case .integer(let i)? where i >= 0: return UInt64(i)
            case .number(let d)? where d >= 0: return UInt64(exactly: d)
            default: return nil
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: `Test Suite 'ComfyRecipeBuilderTests' passed`, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/ComfyRecipeBuilder.swift DiffuselyTests/ComfyRecipeBuilderTests.swift
git commit -m "feat(comfy): recipe builder — single pass, LoRA chain, node attribution

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Recipe builder — latent sources and pass ordering

**Files:**
- Modify: `Diffusely/Services/Media/ComfyRecipeBuilder.swift` (replace `walkLatent` and `orderedPasses`)
- Test: `DiffuselyTests/ComfyRecipeBuilderTests.swift` (append)

**Interfaces:**
- Consumes: Task 4's `Builder`.
- Produces: `walkLatent` handling `.fromPass`, `.image`, upscalers and VAE encode/decode; topological `orderedPasses`.

- [ ] **Step 1: Append the failing tests**

Add inside `ComfyRecipeBuilderTests`:

```swift
    // MARK: - Task 5

    /// Pass "3" (from txt2img) → LatentUpscaleBy(13) → KSampler "2" (deliberately lower id) → VAEDecode(8) → SaveImage(9).
    static func hiresFix() -> ComfyGraph {
        Self.txt2img(extra: [
            Self.node("13", "LatentUpscaleBy", ["samples": Self.link("3"), "upscale_method": Self.str("nearest-exact"), "scale_by": Self.num(1.5)]),
            Self.node("2", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("13"), "seed": Self.int(42), "steps": Self.int(12), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(0.5)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("2"), "vae": Self.link("4", 2)]),
        ])
    }

    @Test func hiresFixIsTwoOrderedPasses() {
        let recipe = ComfyRecipeBuilder.build(Self.hiresFix())
        #expect(recipe.passes.map(\.anchor) == ["3", "2"]) // topological, not numeric
        let first = recipe.passes[0], second = recipe.passes[1]
        #expect(first.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(second.latentSource == .fromPass("3", via: ["LatentUpscaleBy"]))
        #expect(second.sampler.denoise == 0.5)
        #expect(second.nodeIDs.contains("13"))
        #expect(!first.nodeIDs.contains("13"))
        #expect(second.nodeIDs.isSuperset(of: ["8", "9"]))
        #expect(!first.nodeIDs.contains("9"))
        #expect(first.nodeIDs.contains("4") && second.nodeIDs.contains("4")) // shared loader in both
        #expect(recipe.unattributed.isEmpty)
    }

    @Test func img2imgLatentComesFromLoadedImage() {
        let g = Self.txt2img(extra: [
            Self.node("15", "LoadImage", ["image": Self.str("input.png"), "upload": Self.str("image")]),
            Self.node("16", "VAEEncode", ["pixels": Self.link("15"), "vae": Self.link("4", 2)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("16"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(0.7)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.latentSource == .image(loadNode: "15", name: "input.png", via: []))
        #expect(pass.nodeIDs.isSuperset(of: ["15", "16"]))
    }

    @Test func pixelSpaceUpscaleBetweenPassesRecordsViaAndModel() {
        let g = Self.txt2img(extra: [
            Self.node("17", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("4", 2)]),
            Self.node("19", "UpscaleModelLoader", ["model_name": Self.str("4x_foolhardy.pth")]),
            Self.node("18", "ImageUpscaleWithModel", ["upscale_model": Self.link("19"), "image": Self.link("17")]),
            Self.node("20", "VAEEncode", ["pixels": Self.link("18"), "vae": Self.link("4", 2)]),
            Self.node("14", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                         "latent_image": Self.link("20"), "seed": Self.int(1), "steps": Self.int(10), "cfg": Self.num(7),
                                         "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(0.4)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("14"), "vae": Self.link("4", 2)]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        #expect(recipe.passes.map(\.anchor) == ["3", "14"])
        #expect(recipe.passes[1].latentSource == .fromPass("3", via: ["ImageUpscaleWithModel"]))
        #expect(recipe.resources.upscaleModels == ["4x_foolhardy.pth"])
        #expect(recipe.passes[1].nodeIDs.isSuperset(of: ["17", "18", "19", "20"]))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: 3 failures — `hiresFixIsTwoOrderedPasses`, `img2imgLatentComesFromLoadedImage`, `pixelSpaceUpscaleBetweenPassesRecordsViaAndModel`.

- [ ] **Step 3: Replace `walkLatent` and `orderedPasses`**

```swift
        // MARK: Latent

        /// Follows the latent input backwards. Upscalers and VAE hops are noted in
        /// `via`; reaching another sampler yields `.fromPass` (and extracts it).
        mutating func walkLatent(from start: ComfyNodeID, into draft: inout PassDraft) -> LatentSource {
            var via: [String] = []
            var current: ComfyNodeID? = start
            var depth = 0
            var seen = Set<ComfyNodeID>()
            while let id = current, depth < ComfySchema.walkDepthCap, seen.insert(id).inserted {
                depth += 1
                guard let node = graph.nodes[id] else { break }
                let cls = node.classType
                if ComfySchema.samplerAnchors.contains(cls) {
                    extractPassIfNeeded(id)
                    return .fromPass(id, via: via)
                }
                draft.nodeIDs.insert(id)
                if ComfySchema.emptyLatents.contains(cls) {
                    return .empty(width: intWidget(node, "width", &draft),
                                  height: intWidget(node, "height", &draft),
                                  batch: intWidget(node, "batch_size", &draft))
                }
                if ComfySchema.imageLoaders.contains(cls) {
                    return .image(loadNode: id, name: stringWidget(node, "image", &draft), via: via)
                }
                if ComfySchema.latentUpscalers.contains(cls) || ComfySchema.pixelUpscalers.contains(cls) {
                    via.append(cls)
                    attachLoader(node, "upscale_model", into: &draft)
                    current = linkTarget(node, "samples") ?? linkTarget(node, "image")
                    continue
                }
                if ComfySchema.vaeEncoders.contains(cls) {
                    attachLoader(node, "vae", into: &draft)
                    current = linkTarget(node, "pixels")
                    continue
                }
                if ComfySchema.vaeDecoders.contains(cls) {
                    attachLoader(node, "vae", into: &draft)
                    current = linkTarget(node, "samples")
                    continue
                }
                draft.noteUnrecognized(id)
                return .unknown
            }
            return .unknown
        }

        /// Attributes a loader hanging off `key` (a VAE or upscale model) to the
        /// pass and records its resource name.
        mutating func attachLoader(_ node: ComfyNode, _ key: String, into draft: inout PassDraft) {
            guard let loaderID = linkTarget(node, key), let loader = graph.nodes[loaderID] else { return }
            draft.nodeIDs.insert(loaderID)
            recordPlumbingResource(loader)
        }

        // MARK: Ordering and resources

        /// Topological: a pass whose latent comes from another follows it. Ties
        /// (and any malformed cycle) break by numeric id.
        func orderedPasses() -> [SamplingPass] {
            var remaining = Set(drafts.keys)
            var ordered: [SamplingPass] = []
            while !remaining.isEmpty {
                let ready = remaining.filter { id in
                    if case .fromPass(let dep, _) = drafts[id]!.latentSource, remaining.contains(dep) { return false }
                    return true
                }.sorted(by: ComfyGraph.numericIDSort)
                let next = ready.first ?? remaining.sorted(by: ComfyGraph.numericIDSort)[0]
                ordered.append(drafts[next]!.pass)
                remaining.remove(next)
            }
            return ordered
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: `Test Suite 'ComfyRecipeBuilderTests' passed`, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/ComfyRecipeBuilder.swift DiffuselyTests/ComfyRecipeBuilderTests.swift
git commit -m "feat(comfy): latent-source walk and topological pass ordering

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Recipe builder — conditioning extras and advanced samplers

**Files:**
- Modify: `Diffusely/Services/Media/ComfyRecipeBuilder.swift` (replace `readSamplerSettings`, `modelStart`, `conditioningStarts`, `walkConditioning`; add `readSamplerSelect`, `readScheduler`)
- Test: `DiffuselyTests/ComfyRecipeBuilderTests.swift` (append)

**Interfaces:**
- Consumes: Task 5's `Builder`.
- Produces: support for `KSamplerAdvanced`, `SamplerCustom`, `SamplerCustomAdvanced` (Flux cluster), `ConditioningCombine`, ControlNet appliers, `FluxGuidance`, SDXL encoders.

- [ ] **Step 1: Append the failing tests**

```swift
    // MARK: - Task 6

    @Test func conditioningCombineYieldsBothTexts() {
        let g = Self.txt2img(extra: [
            Self.node("61", "CLIPTextEncode", ["text": Self.str("oil painting"), "clip": Self.link("4", 1)]),
            Self.node("60", "ConditioningCombine", ["conditioning_1": Self.link("6"), "conditioning_2": Self.link("61")]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("60"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6"),
                                  ConditioningText(text: "oil painting", nodeID: "61")])
    }

    @Test func controlNetIsRecordedAndTextStillReached() {
        let g = Self.txt2img(extra: [
            Self.node("50", "ControlNetLoader", ["control_net_name": Self.str("canny.safetensors")]),
            Self.node("51", "LoadImage", ["image": Self.str("edges.png")]),
            Self.node("52", "ControlNetApplyAdvanced", ["positive": Self.link("6"), "negative": Self.link("7"),
                                                        "control_net": Self.link("50"), "image": Self.link("51"),
                                                        "strength": Self.num(0.8), "start_percent": Self.num(0), "end_percent": Self.num(1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("52", 0), "negative": Self.link("52", 1),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        let pass = recipe.passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.negative == [ConditioningText(text: "blurry", nodeID: "7")])
        #expect(pass.modifiers.contains("ControlNetApplyAdvanced"))
        #expect(recipe.resources.controlNets == ["canny.safetensors"])
        #expect(pass.nodeIDs.isSuperset(of: ["50", "52"]))
    }

    @Test func sdxlEncoderJoinsDistinctTexts() {
        let g = Self.txt2img(extra: [
            Self.node("6", "CLIPTextEncodeSDXL", ["text_g": Self.str("a cat"), "text_l": Self.str("a cat"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncodeSDXL", ["text_g": Self.str("blurry"), "text_l": Self.str("jpeg artifacts"), "clip": Self.link("4", 1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.negative == [ConditioningText(text: "blurry\njpeg artifacts", nodeID: "7")])
    }

    @Test func kSamplerAdvancedReadsStepRange() {
        let g = Self.txt2img(extra: [
            Self.node("3", "KSamplerAdvanced", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                                "latent_image": Self.link("5"), "add_noise": Self.str("enable"), "noise_seed": Self.int(5),
                                                "steps": Self.int(30), "cfg": Self.num(6), "sampler_name": Self.str("dpmpp_2m"),
                                                "scheduler": Self.str("karras"), "start_at_step": Self.int(0), "end_at_step": Self.int(20),
                                                "return_with_leftover_noise": Self.str("disable")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.sampler == SamplerSettings(seed: 5, steps: 30, cfg: 6, samplerName: "dpmpp_2m",
                                                scheduler: "karras", denoise: nil, startStep: 0, endStep: 20))
    }

    @Test func fluxSamplerCustomAdvancedCluster() {
        let g = Self.graph([
            Self.node("30", "UNETLoader", ["unet_name": Self.str("flux1-dev.safetensors"), "weight_dtype": Self.str("default")]),
            Self.node("31", "DualCLIPLoader", ["clip_name1": Self.str("t5xxl.safetensors"), "clip_name2": Self.str("clip_l.safetensors"), "type": Self.str("flux")]),
            Self.node("32", "CLIPTextEncode", ["text": Self.str("a fox"), "clip": Self.link("31")]),
            Self.node("33", "FluxGuidance", ["conditioning": Self.link("32"), "guidance": Self.num(3.5)]),
            Self.node("34", "BasicGuider", ["model": Self.link("30"), "conditioning": Self.link("33")]),
            Self.node("35", "RandomNoise", ["noise_seed": Self.int(123)]),
            Self.node("36", "KSamplerSelect", ["sampler_name": Self.str("euler")]),
            Self.node("37", "BasicScheduler", ["model": Self.link("30"), "scheduler": Self.str("simple"), "steps": Self.int(20), "denoise": Self.num(1)]),
            Self.node("38", "EmptySD3LatentImage", ["width": Self.int(1024), "height": Self.int(1024), "batch_size": Self.int(1)]),
            Self.node("39", "SamplerCustomAdvanced", ["noise": Self.link("35"), "guider": Self.link("34"), "sampler": Self.link("36"),
                                                      "sigmas": Self.link("37"), "latent_image": Self.link("38")]),
            Self.node("40", "VAELoader", ["vae_name": Self.str("ae.safetensors")]),
            Self.node("41", "VAEDecode", ["samples": Self.link("39", 0), "vae": Self.link("40")]),
            Self.node("42", "SaveImage", ["images": Self.link("41")]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        #expect(recipe.passes.count == 1)
        let pass = recipe.passes[0]
        #expect(pass.anchor == "39")
        #expect(pass.sampler == SamplerSettings(seed: 123, steps: 20, cfg: 3.5, samplerName: "euler",
                                                scheduler: "simple", denoise: 1))
        #expect(pass.modelChain == [.base(name: "flux1-dev.safetensors", classType: "UNETLoader")])
        #expect(pass.positive == [ConditioningText(text: "a fox", nodeID: "32")])
        #expect(pass.negative.isEmpty)
        #expect(pass.modifiers.contains("FluxGuidance"))
        #expect(pass.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(recipe.resources.vaes == ["ae.safetensors"])
        #expect(pass.nodeIDs.isSuperset(of: ["34", "35", "36", "37", "33", "32"]))
        #expect(recipe.unattributed == ["31"]) // the CLIP loader is not on any role walk
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: 5 new failures (`conditioningCombineYieldsBothTexts`, `controlNetIsRecordedAndTextStillReached`, `sdxlEncoderJoinsDistinctTexts` may already pass via `encodedText`; the others fail).

- [ ] **Step 3: Replace the sampler-settings and conditioning functions**

```swift
        mutating func readSamplerSettings(_ node: ComfyNode, into draft: inout PassDraft) {
            switch node.classType {
            case "KSampler":
                draft.sampler.seed = seedWidget(node, "seed", &draft)
                draft.sampler.steps = intWidget(node, "steps", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                draft.sampler.samplerName = stringWidget(node, "sampler_name", &draft)
                draft.sampler.scheduler = stringWidget(node, "scheduler", &draft)
                draft.sampler.denoise = doubleWidget(node, "denoise", &draft)
            case "KSamplerAdvanced":
                draft.sampler.seed = seedWidget(node, "noise_seed", &draft)
                draft.sampler.steps = intWidget(node, "steps", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                draft.sampler.samplerName = stringWidget(node, "sampler_name", &draft)
                draft.sampler.scheduler = stringWidget(node, "scheduler", &draft)
                draft.sampler.startStep = intWidget(node, "start_at_step", &draft)
                draft.sampler.endStep = intWidget(node, "end_at_step", &draft)
            case "SamplerCustom":
                draft.sampler.seed = seedWidget(node, "noise_seed", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                if let s = linkTarget(node, "sampler") { readSamplerSelect(s, into: &draft) }
                if let s = linkTarget(node, "sigmas") { readScheduler(s, into: &draft) }
            case "SamplerCustomAdvanced":
                if let n = linkTarget(node, "noise"), let noise = graph.nodes[n] {
                    draft.nodeIDs.insert(n)
                    draft.sampler.seed = seedWidget(noise, "noise_seed", &draft) ?? seedWidget(noise, "seed", &draft)
                }
                if let s = linkTarget(node, "sampler") { readSamplerSelect(s, into: &draft) }
                if let s = linkTarget(node, "sigmas") { readScheduler(s, into: &draft) }
            default:
                break
            }
        }

        /// `KSamplerSelect` carries a name; the dedicated `SamplerEulerAncestral`
        /// style nodes are named by their class.
        mutating func readSamplerSelect(_ id: ComfyNodeID, into draft: inout PassDraft) {
            guard let node = graph.nodes[id] else { return }
            draft.nodeIDs.insert(id)
            switch node.classType {
            case "KSamplerSelect": draft.sampler.samplerName = stringWidget(node, "sampler_name", &draft)
            case "ODESamplerSelect": draft.sampler.samplerName = stringWidget(node, "solver", &draft)
            default: draft.sampler.samplerName = node.classType
            }
        }

        /// `BasicScheduler` carries a scheduler name; `KarrasScheduler` and friends are
        /// named by their class.
        mutating func readScheduler(_ id: ComfyNodeID, into draft: inout PassDraft) {
            guard let node = graph.nodes[id] else { return }
            draft.nodeIDs.insert(id)
            draft.sampler.steps = intWidget(node, "steps", &draft)
            draft.sampler.scheduler = stringWidget(node, "scheduler", &draft) ?? node.classType
            draft.sampler.denoise = doubleWidget(node, "denoise", &draft)
        }

        /// `SamplerCustomAdvanced` takes its model through the guider.
        mutating func modelStart(_ node: ComfyNode, into draft: inout PassDraft) -> ComfyNodeID? {
            guard node.classType == "SamplerCustomAdvanced" else { return linkTarget(node, "model") }
            guard let g = linkTarget(node, "guider"), let guider = graph.nodes[g] else { return nil }
            draft.nodeIDs.insert(g)
            return linkTarget(guider, "model")
        }

        /// `BasicGuider` has one `conditioning`; `CFGGuider` / `DualCFGGuider` have
        /// positive/negative and carry the cfg.
        mutating func conditioningStarts(_ node: ComfyNode, into draft: inout PassDraft)
            -> (positive: ComfyNodeID?, negative: ComfyNodeID?) {
            guard node.classType == "SamplerCustomAdvanced" else {
                return (linkTarget(node, "positive"), linkTarget(node, "negative"))
            }
            guard let g = linkTarget(node, "guider"), let guider = graph.nodes[g] else { return (nil, nil) }
            draft.nodeIDs.insert(g)
            if draft.sampler.cfg == nil { draft.sampler.cfg = doubleWidget(guider, "cfg", &draft) }
            return (linkTarget(guider, "positive") ?? linkTarget(guider, "conditioning"),
                    linkTarget(guider, "negative"))
        }

        // MARK: Conditioning

        mutating func walkConditioning(from start: ComfyNodeID, negative: Bool,
                                       into draft: inout PassDraft, depth: Int = 0) -> [ConditioningText] {
            guard depth < ComfySchema.walkDepthCap, let node = graph.nodes[start] else { return [] }
            draft.nodeIDs.insert(start)
            let cls = node.classType

            if ComfySchema.textEncoders.contains(cls) {
                return [ConditioningText(text: encodedText(node, &draft), nodeID: start)]
            }
            if ComfySchema.conditioningCombiners.contains(cls) {
                var texts: [ConditioningText] = []
                for input in node.inputs {
                    guard case .link(let target, _) = input.value else { continue }
                    texts += walkConditioning(from: target, negative: negative, into: &draft, depth: depth + 1)
                }
                return texts
            }
            if ComfySchema.controlNetAppliers.contains(cls) {
                if let loaderID = linkTarget(node, "control_net"), let loader = graph.nodes[loaderID] {
                    draft.nodeIDs.insert(loaderID)
                    if let name = literalString(loader, "control_net_name"), !controlNets.contains(name) {
                        controlNets.append(name)
                    }
                }
                if !draft.modifiers.contains(cls) { draft.modifiers.append(cls) }
                let nextKey = negative ? "negative" : "positive"
                guard let next = linkTarget(node, nextKey) ?? linkTarget(node, "conditioning") else { return [] }
                return walkConditioning(from: next, negative: negative, into: &draft, depth: depth + 1)
            }
            if ComfySchema.guidanceModifiers.contains(cls) {
                if draft.sampler.cfg == nil { draft.sampler.cfg = doubleWidget(node, "guidance", &draft) }
                if !draft.modifiers.contains(cls) { draft.modifiers.append(cls) }
                guard let next = linkTarget(node, "conditioning") else { return [] }
                return walkConditioning(from: next, negative: negative, into: &draft, depth: depth + 1)
            }
            if ComfySchema.conditioningPassThrough.contains(cls) {
                if !draft.modifiers.contains(cls) { draft.modifiers.append(cls) }
                guard let next = linkTarget(node, "conditioning") else { return [] }
                return walkConditioning(from: next, negative: negative, into: &draft, depth: depth + 1)
            }
            draft.noteUnrecognized(start)
            return []
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: `Test Suite 'ComfyRecipeBuilderTests' passed`, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/ComfyRecipeBuilder.swift DiffuselyTests/ComfyRecipeBuilderTests.swift
git commit -m "feat(comfy): advanced samplers, Flux guider cluster, ControlNet and combined conditioning

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Recipe builder — unknown-node pass-through and malformed graphs

**Files:**
- Modify: `Diffusely/Services/Media/ComfyRecipeBuilder.swift` (add `passThrough`; replace the unknown branches in `walkModel`, `walkConditioning`, `walkLatent`)
- Test: `DiffuselyTests/ComfyRecipeBuilderTests.swift` (append)

**Interfaces:**
- Consumes: Task 6's `Builder`.
- Produces: `func passThrough(_ node: ComfyNode, role: ComfyRole, negative: Bool = false) -> ComfyNodeID?`.

- [ ] **Step 1: Append the failing tests**

```swift
    // MARK: - Task 7

    @Test func unknownModelNodeIsPassedThroughAndReported() {
        let g = Self.txt2img(samplerModel: "70", extra: [
            Self.node("70", "SomeCustomPatch", ["model": Self.link("4"), "strength": Self.num(0.3)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [.base(name: "sdxl_base.safetensors", classType: "CheckpointLoaderSimple")])
        #expect(pass.unrecognized == ["70"])
        #expect(pass.nodeIDs.contains("70"))
    }

    @Test func unknownTerminalNodeEndsChainWithUnknownBase() {
        let g = Self.txt2img(samplerModel: "71", extra: [
            Self.node("71", "MysteryLoader", ["path": Self.str("/models/x")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [.base(name: nil, classType: "MysteryLoader")])
        #expect(pass.unrecognized == ["71"])
    }

    @Test func unknownConditioningNodeIsPassedThrough() {
        let g = Self.txt2img(extra: [
            Self.node("72", "CustomPromptBooster", ["conditioning": Self.link("6"), "boost": Self.num(2)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("72"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.unrecognized == ["72"])
    }

    @Test func unknownLatentNodeIsPassedThrough() {
        let g = Self.txt2img(extra: [
            Self.node("73", "LatentNoiseInjector", ["samples": Self.link("5"), "amount": Self.num(0.1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("73"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(pass.unrecognized == ["73"])
    }

    @Test func unknownLatentNodeWithNoMatchingInputIsUnknownSource() {
        let g = Self.txt2img(extra: [
            Self.node("74", "LatentFromNowhere", ["seed": Self.int(9)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("74"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.latentSource == .unknown)
        #expect(pass.unrecognized == ["74"])
    }

    @Test func modelCycleTerminates() {
        let g = Self.txt2img(samplerModel: "80", extra: [
            Self.node("80", "LoraLoader", ["model": Self.link("81"), "lora_name": Self.str("a"), "strength_model": Self.num(1), "strength_clip": Self.num(1)]),
            Self.node("81", "LoraLoader", ["model": Self.link("80"), "lora_name": Self.str("b"), "strength_model": Self.num(1), "strength_clip": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain.count == 3)
        #expect(pass.modelChain[0] == .base(name: nil, classType: "unknown"))
    }

    @Test func mutualLatentCycleTerminates() {
        // Two samplers feeding each other's latent — impossible in ComfyUI, but
        // the builder must not recurse forever.
        let g = Self.graph([
            Self.node("4", "CheckpointLoaderSimple", ["ckpt_name": Self.str("m")]),
            Self.node("6", "CLIPTextEncode", ["text": Self.str("p"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncode", ["text": Self.str("n"), "clip": Self.link("4", 1)]),
            Self.node("1", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"), "latent_image": Self.link("2"),
                                        "seed": Self.int(1), "steps": Self.int(1), "cfg": Self.num(1), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
            Self.node("2", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"), "latent_image": Self.link("1"),
                                        "seed": Self.int(2), "steps": Self.int(1), "cfg": Self.num(1), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("2"), "vae": Self.link("4", 2)]),
            Self.node("9", "SaveImage", ["images": Self.link("8")]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        #expect(recipe.passes.count == 2)
    }

    @Test func danglingLinksResolveToNothing() {
        let g = Self.txt2img(samplerModel: "404")
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [.base(name: nil, classType: "unknown")])
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: failures in `unknownModelNodeIsPassedThroughAndReported`, `unknownConditioningNodeIsPassedThrough`, `unknownLatentNodeIsPassedThrough`; the cycle and dangling tests should already pass (the walks have visited sets and nil-guards).

- [ ] **Step 3: Add `passThrough` and use it in the three walks**

Add to `Builder`:

```swift
        // MARK: Unknown nodes

        /// The input to follow through a node the schema doesn't know, by role.
        /// Conditioning prefers the side being walked (`positive` vs `negative`).
        func passThrough(_ node: ComfyNode, role: ComfyRole, negative: Bool = false) -> ComfyNodeID? {
            let keys: [String]
            switch role {
            case .conditioning: keys = negative ? ["negative", "conditioning"] : ["positive", "conditioning"]
            default: keys = ComfySchema.passThroughInputs[role] ?? []
            }
            for key in keys {
                if let target = linkTarget(node, key) { return target }
            }
            return nil
        }
```

Replace the final `else` branch of the `while` in `walkModel`:

```swift
                } else if let next = passThrough(node, role: .model) {
                    draft.noteUnrecognized(id)
                    current = next
                } else {
                    draft.noteUnrecognized(id)
                    base = .base(name: nil, classType: cls)
                    break
                }
```

Replace the last two lines of `walkConditioning` (`draft.noteUnrecognized(start); return []`):

```swift
            draft.noteUnrecognized(start)
            guard let next = passThrough(node, role: .conditioning, negative: negative) else { return [] }
            return walkConditioning(from: next, negative: negative, into: &draft, depth: depth + 1)
```

Replace the last two lines inside the `while` of `walkLatent` (`draft.noteUnrecognized(id); return .unknown`):

```swift
                draft.noteUnrecognized(id)
                guard let next = passThrough(node, role: .latent) else { return .unknown }
                current = next
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyRecipeBuilderTests 2>&1 | tail -25`
Expected: `Test Suite 'ComfyRecipeBuilderTests' passed`, 21 tests.

- [ ] **Step 5: Commit**

```bash
git add Diffusely/Services/Media/ComfyRecipeBuilder.swift DiffuselyTests/ComfyRecipeBuilderTests.swift
git commit -m "feat(comfy): pass through unrecognized nodes instead of stopping

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: EmbeddedMetadata envelope and reader format detection

**Files:**
- Modify: `Diffusely/Models/Civitai/EmbeddedMetadata.swift` (replace `GenerationParameters`? no — replace only `EmbeddedMetadata`; keep `GenerationParameters` and `A1111ParametersParser` untouched)
- Modify: `Diffusely/Services/Media/EmbeddedMetadataReader.swift` (whole file replaced below)
- Modify: `DiffuselyTests/EmbeddedMetadataReaderTests.swift` (update `source` assertions, add cases)

**Interfaces:**
- Consumes: `MediaContainer` (Task 1), `ComfyGraphParser` (Task 2), `ComfyRecipeBuilder` (Task 4–7).
- Produces: `struct EmbeddedMetadata { fields: [String: String]; container: MediaContainer; format: Format; raw: String; parameters: GenerationParameters?; comfy: ComfyPayload? }` with `enum Format { automatic1111, comfyUI, unknown }`; `struct ComfyPayload { promptJSON, workflowJSON, graph, recipe, error }` with `static func make(prompt:workflow:) -> ComfyPayload`; `EmbeddedMetadataReader.metadata(fields:container:) -> EmbeddedMetadata?`, `comfyJSONFields(_:) -> (prompt: String?, workflow: String?)`, plus the unchanged `read(data:)`, `read(fileURL:)`, `pngTextChunks(in:)`.

- [ ] **Step 1: Update the existing tests to the new shape**

In `DiffuselyTests/EmbeddedMetadataReaderTests.swift`, apply this mapping everywhere it occurs (lines ~139, 149, 174, 190, 198, 208, 219):

| Old assertion | New assertion |
|---|---|
| `meta?.source == .pngText(keyword: "parameters")` | `meta?.container == .png` and `meta?.fields["parameters"] != nil` |
| `meta?.source == .pngText(keyword: "Comment")` | `meta?.container == .png` and `meta?.fields["Comment"] != nil` |
| `meta?.source == .exifUserComment` | `meta?.container == .jpeg` and `meta?.fields["UserComment"] != nil` |
| `EmbeddedMetadataReader.read(fileURL: url)?.source == .pngText(keyword: K)` | `EmbeddedMetadataReader.read(fileURL: url)?.fields[K] != nil` |

Also, in `readsUserCommentFromJPEGFile` and its `read(data:)` twin, add `#expect(meta?.format == .unknown)`; in `parsesA1111ShapedUserCommentFromJPEG` add `#expect(meta?.format == .automatic1111)`.

- [ ] **Step 2: Append the new failing tests**

```swift
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
```

Note on `malformedPromptIsComfyWithError`: the detector decides `.comfyUI` from a *lenient* decode that succeeds after `cleanBadJSON`; a string that never decodes isn't recognized as Comfy at all. The second input decodes leniently as a graph? No — `[NaN}` is broken even after cleaning, so the detector must fall back to a cheap structural sniff: text that starts with `{` and contains `"class_type"` is treated as a Comfy prompt so that the payload can carry `.malformedJSON`. Implement exactly that in `looksLikeComfyPrompt`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: build failure — `EmbeddedMetadata` has no member `fields` / `container` / `format`.

- [ ] **Step 4: Replace `EmbeddedMetadata` in `Diffusely/Models/Civitai/EmbeddedMetadata.swift`**

Delete the existing `struct EmbeddedMetadata` (and its `Source` enum) and insert this in its place. `GenerationParameters` and `A1111ParametersParser` stay exactly as they are.

```swift
/// Everything recognized in an image file's embedded metadata, plus whatever
/// the detected format could parse out of it. View-only: nothing here is
/// persisted to the sidecar or the index.
struct EmbeddedMetadata: Equatable {
    enum Format: Equatable {
        case automatic1111, comfyUI, unknown
    }

    /// Every recognized text field keyed by its source name. PNG: the `tEXt`
    /// keyword. EXIF: "UserComment", and "Model" for the WebP variant.
    let fields: [String: String]
    let container: MediaContainer
    let format: Format
    /// Verbatim text for the Raw disclosure. A1111: the parameters string.
    /// ComfyUI: the `workflow` JSON if present (the loadable one), else `prompt`.
    let raw: String
    /// Non-nil iff `format == .automatic1111`.
    let parameters: GenerationParameters?
    /// Non-nil iff `format == .comfyUI`.
    let comfy: ComfyPayload?
}

/// The two ComfyUI chunks plus what could be built from them. `graph` and
/// `recipe` are nil when `error` is set; the JSON strings are kept regardless
/// so Raw and export still work.
struct ComfyPayload: Equatable {
    let promptJSON: String?
    let workflowJSON: String?
    let graph: ComfyGraph?
    let recipe: ComfyRecipe?
    let error: ComfyParseError?

    static func make(prompt: String?, workflow: String?) -> ComfyPayload {
        guard let prompt else {
            return ComfyPayload(promptJSON: nil, workflowJSON: workflow, graph: nil, recipe: nil, error: .noPromptGraph)
        }
        do {
            let graph = try ComfyGraphParser.parse(prompt: prompt, workflow: workflow)
            return ComfyPayload(promptJSON: prompt, workflowJSON: workflow, graph: graph,
                                recipe: ComfyRecipeBuilder.build(graph), error: nil)
        } catch let error as ComfyParseError {
            return ComfyPayload(promptJSON: prompt, workflowJSON: workflow, graph: nil, recipe: nil, error: error)
        } catch {
            return ComfyPayload(promptJSON: prompt, workflowJSON: workflow, graph: nil, recipe: nil, error: .malformedJSON)
        }
    }
}
```

- [ ] **Step 5: Replace `Diffusely/Services/Media/EmbeddedMetadataReader.swift` entirely**

```swift
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
                result = metadata(fields: exifFields(from: source), container: container)
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
            return metadata(fields: exifFields(from: source), container: container)
        }
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
```

- [ ] **Step 6: Run the reader tests**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: `Test Suite 'EmbeddedMetadataReaderTests' passed` — all pre-existing cases plus 11 new ones.

- [ ] **Step 7: Fix the one call site and confirm both platforms build**

`Diffusely/Views/EmbeddedMetadataView.swift` reads `metadata.parameters` and `metadata.raw` only — both still exist, so it compiles unchanged. Confirm:

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | tail -5`
Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 8: Commit**

```bash
git add Diffusely/Models/Civitai/EmbeddedMetadata.swift Diffusely/Services/Media/EmbeddedMetadataReader.swift DiffuselyTests/EmbeddedMetadataReaderTests.swift
git commit -m "feat(media): keep every embedded text field, detect format, parse ComfyUI in the reader

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: EXIF UserComment byte decoder and JPEG APP1 scanner

**Files:**
- Create: `Diffusely/Services/Media/ExifUserCommentDecoder.swift`
- Modify: `Diffusely/Services/Media/EmbeddedMetadataReader.swift` (wire the fallback into `read(data:)` and `read(fileURL:)`)
- Test: `DiffuselyTests/ExifUserCommentDecoderTests.swift`

**Interfaces:**
- Produces: `ExifUserCommentDecoder.decode(_ bytes: Data) -> String?`; `JPEGExifScanner.userCommentBytes(in data: Data) -> Data?`.

Why: ImageIO usually hands back UserComment as a decoded `String`, but Civitai needed 40 lines of charset handling (`encoding-helpers.ts:50`) for real uploads. When ImageIO yields nothing or replacement characters for a JPEG, read the raw tag and decode it ourselves. The spec gates the BOM-less endianness *heuristic* on a real fixture; it is not implemented here — a BOM-less `UNICODE` comment is tried big-endian then little-endian, which covers the writers observed so far.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct ExifUserCommentDecoderTests {
    private func header(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(Data(repeating: 0, count: 8 - d.count))
        return d
    }

    @Test func decodesASCIIHeader() {
        let bytes = header("ASCII") + Data("hello".utf8)
        #expect(ExifUserCommentDecoder.decode(bytes) == "hello")
    }

    @Test func decodesUTF8Header() {
        let bytes = header("UTF8") + Data("héllo".utf8)
        #expect(ExifUserCommentDecoder.decode(bytes) == "héllo")
    }

    @Test func decodesUnicodeBigEndianWithBOM() {
        var bytes = header("UNICODE")
        bytes.append(contentsOf: [0xFE, 0xFF])
        bytes.append("hi".data(using: .utf16BigEndian)!)
        #expect(ExifUserCommentDecoder.decode(bytes) == "hi")
    }

    @Test func decodesUnicodeLittleEndianWithBOM() {
        var bytes = header("UNICODE")
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append("hi".data(using: .utf16LittleEndian)!)
        #expect(ExifUserCommentDecoder.decode(bytes) == "hi")
    }

    @Test func decodesUnicodeWithoutBOMAsBigEndian() {
        let bytes = header("UNICODE") + "{\"a\":1}".data(using: .utf16BigEndian)!
        #expect(ExifUserCommentDecoder.decode(bytes) == "{\"a\":1}")
    }

    @Test func stripsTrailingNulsAndRejectsShortInput() {
        let bytes = header("ASCII") + Data("x\0\0".utf8)
        #expect(ExifUserCommentDecoder.decode(bytes) == "x")
        #expect(ExifUserCommentDecoder.decode(Data([1, 2, 3])) == nil)
    }

    @Test func scannerFindsUserCommentInRealJPEG() throws {
        let url = try EmbeddedMetadataReaderTests.makeJPEGWithUserComment("scan me")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let raw = try #require(JPEGExifScanner.userCommentBytes(in: data))
        #expect(ExifUserCommentDecoder.decode(raw) == "scan me")
    }

    @Test func scannerReturnsNilForNonJPEGOrNoExif() {
        #expect(JPEGExifScanner.userCommentBytes(in: Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(JPEGExifScanner.userCommentBytes(in: Data([0xFF, 0xD8, 0xFF, 0xD9])) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ExifUserCommentDecoderTests 2>&1 | tail -25`
Expected: build failure, `cannot find 'ExifUserCommentDecoder' in scope`.

- [ ] **Step 3: Write the decoder and scanner**

`Diffusely/Services/Media/ExifUserCommentDecoder.swift`:

```swift
import Foundation

/// Decodes the raw EXIF `UserComment` payload (tag 0x9286): an 8-byte character
/// code followed by text. Port of the header/BOM branches of Civitai's
/// `decodeUserComment`; the BOM-less endianness heuristic is deliberately
/// omitted until a real image needs it.
enum ExifUserCommentDecoder {
    static func decode(_ bytes: Data) -> String? {
        guard bytes.count >= 8 else { return nil }
        let header = String(decoding: bytes.prefix(8), as: UTF8.self)
        let body = Data(bytes.dropFirst(8))
        let decoded: String?
        if header.hasPrefix("ASCII") {
            decoded = String(data: body, encoding: .ascii) ?? String(decoding: body, as: UTF8.self)
        } else if header.hasPrefix("UTF8") || header.hasPrefix("UTF-8") {
            decoded = String(decoding: body, as: UTF8.self)
        } else if header.hasPrefix("UNICODE") {
            if body.count >= 2, body[0] == 0xFE, body[1] == 0xFF {
                decoded = String(data: body.dropFirst(2), encoding: .utf16BigEndian)
            } else if body.count >= 2, body[0] == 0xFF, body[1] == 0xFE {
                decoded = String(data: body.dropFirst(2), encoding: .utf16LittleEndian)
            } else {
                decoded = String(data: body, encoding: .utf16BigEndian)
                    ?? String(data: body, encoding: .utf16LittleEndian)
            }
        } else {
            // Undefined / all-zero code: treat as UTF-8 text.
            decoded = String(decoding: body, as: UTF8.self)
        }
        return decoded?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}

/// Finds the raw `UserComment` bytes inside a JPEG's APP1 Exif segment by
/// walking IFD0 → Exif IFD. Only used when ImageIO's decoded string is empty
/// or damaged.
enum JPEGExifScanner {
    static func userCommentBytes(in data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA || marker == 0xD9 { break } // SOS / EOI: headers are over
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return nil }
            if marker == 0xE1, length > 8, Array(b[(i + 4)..<(i + 10)]) == Array("Exif\0\0".utf8) {
                return userComment(inTIFF: Array(b[(i + 10)..<(i + 2 + length)]))
            }
            i += 2 + length
        }
        return nil
    }

    private static func userComment(inTIFF t: [UInt8]) -> Data? {
        guard t.count >= 8 else { return nil }
        let little: Bool
        if t[0] == 0x49, t[1] == 0x49 { little = true }
        else if t[0] == 0x4D, t[1] == 0x4D { little = false }
        else { return nil }

        func u16(_ o: Int) -> Int {
            guard o >= 0, o + 2 <= t.count else { return 0 }
            return little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o >= 0, o + 4 <= t.count else { return 0 }
            return little
                ? Int(t[o]) | Int(t[o + 1]) << 8 | Int(t[o + 2]) << 16 | Int(t[o + 3]) << 24
                : Int(t[o]) << 24 | Int(t[o + 1]) << 16 | Int(t[o + 2]) << 8 | Int(t[o + 3])
        }
        /// Returns (count, offset of the 4-byte value/offset field) for a tag in an IFD.
        func find(tag: Int, inIFD offset: Int) -> (count: Int, valueField: Int)? {
            guard offset > 0, offset + 2 <= t.count else { return nil }
            let n = u16(offset)
            for k in 0..<n {
                let e = offset + 2 + k * 12
                guard e + 12 <= t.count else { return nil }
                if u16(e) == tag { return (u32(e + 4), e + 8) }
            }
            return nil
        }

        guard let exifPointer = find(tag: 0x8769, inIFD: u32(4)) else { return nil }
        let exifIFD = u32(exifPointer.valueField)
        guard let comment = find(tag: 0x9286, inIFD: exifIFD) else { return nil }
        let start = comment.count <= 4 ? comment.valueField : u32(comment.valueField)
        guard start >= 0, comment.count >= 0, start + comment.count <= t.count else { return nil }
        return Data(t[start..<(start + comment.count)])
    }
}
```

- [ ] **Step 4: Wire the fallback into the reader**

In `EmbeddedMetadataReader`, add:

```swift
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
```

In `read(data:)`'s `default:` branch, change the last line to:

```swift
            var fields = exifFields(from: source)
            if container == .jpeg { repairUserComment(in: &fields, jpegBytes: data) }
            return metadata(fields: fields, container: container)
```

In `read(fileURL:)`'s `default:` branch, likewise:

```swift
                var fields = exifFields(from: source)
                if container == .jpeg { repairUserComment(in: &fields, jpegBytes: prefix) }
                result = metadata(fields: fields, container: container)
```

(`prefix` is the 1 MiB header read; APP1 is capped at 64 KiB so it is always inside it.)

- [ ] **Step 5: Run the decoder and reader tests**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ExifUserCommentDecoderTests -only-testing:DiffuselyTests/EmbeddedMetadataReaderTests 2>&1 | tail -25`
Expected: both suites pass.

- [ ] **Step 6: Commit**

```bash
git add Diffusely/Services/Media/ExifUserCommentDecoder.swift Diffusely/Services/Media/EmbeddedMetadataReader.swift DiffuselyTests/ExifUserCommentDecoderTests.swift
git commit -m "feat(media): decode raw EXIF UserComment bytes when ImageIO's string is unusable

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Recipe view, shared field grid, export document

**Files:**
- Create: `Diffusely/Views/MetadataFieldGrid.swift`
- Create: `Diffusely/Utilities/DataDocument.swift`
- Create: `Diffusely/Views/ComfyRecipeView.swift`
- Modify: `Diffusely/Views/EmbeddedMetadataView.swift` (switch on format; use `MetadataFieldGrid`; new init parameters)

**Interfaces:**
- Consumes: `EmbeddedMetadata`, `ComfyPayload`, `MediaContainer`, `CopyablePromptView(label:text:)` (in `ImageDetailView.swift`), `Clipboard.copy(_:)`.
- Produces: `MetadataFieldGrid(fields: [GenerationParameters.Field])`; `DataDocument(data:contentType:)`; `ComfyRecipeView(payload:itemID:loadOriginalBytes:)`; `EmbeddedMetadataView(metadata:itemID:loadOriginalBytes:)`. `Route.comfyNodes` and `ComfyInspectorPayload` are referenced here and defined in Task 11 — do Task 10 and Task 11 back to back before building; the build at the end of Task 11 covers both.

No unit tests (views). Verified by the builds at the end of Task 11 and the smoke run in Task 14.

- [ ] **Step 1: Extract the field grid**

`Diffusely/Views/MetadataFieldGrid.swift`:

```swift
import SwiftUI

/// Two-column key/value grid used by every embedded-metadata format.
struct MetadataFieldGrid: View {
    let fields: [GenerationParameters.Field]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                GridRow {
                    Text(field.key)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.leading)
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

- [ ] **Step 2: Add the export document**

`Diffusely/Utilities/DataDocument.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` so `.fileExporter` can write arbitrary bytes under a
/// caller-chosen type. Read support exists only to satisfy the protocol.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.json, .png, .jpeg, .webP, .data] }

    let data: Data
    let contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
```

- [ ] **Step 3: Write the recipe view**

`Diffusely/Views/ComfyRecipeView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// The structural summary of a ComfyUI graph: resources, then one card per
/// sampling pass in execution order, then "All Nodes" and export. Rendered
/// inline in the Library detail scroll by `EmbeddedMetadataView`.
struct ComfyRecipeView: View {
    let payload: ComfyPayload
    let itemID: Int
    /// Decrypted original bytes for "Save Original Image…". Runs off-main.
    let loadOriginalBytes: () async -> Data?

    @State private var exportDocument: DataDocument?
    @State private var exportFilename = ""
    @State private var showExporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recipe = payload.recipe, let graph = payload.graph {
                Text("ComfyUI workflow · \(graph.nodes.count) nodes · \(recipe.passes.count) \(recipe.passes.count == 1 ? "pass" : "passes")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                resources(recipe.resources)
                ForEach(Array(recipe.passes.enumerated()), id: \.element.anchor) { index, pass in
                    PassCard(pass: pass, number: recipe.passes.count > 1 ? index + 1 : nil)
                }
                HStack {
                    NavigationLink(value: Route.comfyNodes(ComfyInspectorPayload(graph: graph, recipe: recipe, title: "#\(itemID)"))) {
                        Label("All Nodes", systemImage: "list.bullet.indent")
                    }
                    Spacer()
                    exportMenu
                }
                .font(.subheadline)
            } else {
                Text(unavailableMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack { Spacer(); exportMenu }
                    .font(.subheadline)
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: exportDocument?.contentType ?? .data,
                      defaultFilename: exportFilename) { _ in }
    }

    private var unavailableMessage: String {
        switch payload.error {
        case .noPromptGraph:
            return "This image carries only ComfyUI's UI workflow, not the API graph, so there is nothing to summarize. The JSON is still available below and in Export."
        case .malformedJSON:
            return "Couldn't read this ComfyUI workflow — the embedded JSON is malformed. The raw text is still available below."
        case .notAGraph, .none:
            return "Couldn't read this ComfyUI workflow. The raw text is still available below."
        }
    }

    // MARK: Resources

    @ViewBuilder
    private func resources(_ r: ResourceSummary) -> some View {
        let fields: [GenerationParameters.Field] =
            r.baseModels.map { .init(key: "Model", value: $0) }
            + r.loras.map { .init(key: "LoRA", value: $0.strength.map { s in "\($0.name) (\(Self.format(s)))" } ?? $0.name) }
            + r.vaes.map { .init(key: "VAE", value: $0) }
            + r.controlNets.map { .init(key: "ControlNet", value: $0) }
            + r.upscaleModels.map { .init(key: "Upscaler", value: $0) }
        if !fields.isEmpty {
            MetadataFieldGrid(fields: fields)
        }
    }

    // MARK: Export

    private var exportMenu: some View {
        Menu {
            if let workflow = payload.workflowJSON {
                Button("Copy Workflow JSON") { Clipboard.copy(workflow) }
                Button("Save Workflow…") { present(Data(workflow.utf8), .json, "\(itemID).workflow.json") }
            }
            if let prompt = payload.promptJSON {
                Button("Copy API Prompt JSON") { Clipboard.copy(prompt) }
                Button("Save API Prompt…") { present(Data(prompt.utf8), .json, "\(itemID).api.json") }
            }
            Divider()
            Button("Save Original Image…") {
                Task { @MainActor in
                    guard let bytes = await loadOriginalBytes() else { return }
                    let container = MediaContainer.detect(bytes)
                    present(bytes, container.utType, "\(itemID).\(container.fileExtension)")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private func present(_ data: Data, _ type: UTType, _ filename: String) {
        exportDocument = DataDocument(data: data, contentType: type)
        exportFilename = filename
        showExporter = true
    }

    static func format(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
    }
}

/// One sampling pass: settings grid, model chain, prompts, latent source, notes.
private struct PassCard: View {
    let pass: SamplingPass
    let number: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number.map { "Pass \($0) — \(pass.anchorClass)" } ?? pass.anchorClass)
                .font(.subheadline.weight(.semibold))

            if !samplerFields.isEmpty {
                MetadataFieldGrid(fields: samplerFields)
            }

            Text(modelChainLine)
                .font(.caption)
                .textSelection(.enabled)

            ForEach(pass.positive, id: \.self) { CopyablePromptView(label: "Prompt", text: $0.text) }
            ForEach(pass.negative, id: \.self) { CopyablePromptView(label: "Negative Prompt", text: $0.text) }

            Text(latentLine)
                .font(.caption)
                .foregroundColor(.secondary)

            if !pass.modifiers.isEmpty {
                Text(pass.modifiers.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !pass.unrecognized.isEmpty {
                Text("via \(pass.unrecognized.count) unrecognized node\(pass.unrecognized.count == 1 ? "" : "s") — see All Nodes")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var samplerFields: [GenerationParameters.Field] {
        let s = pass.sampler
        var f: [GenerationParameters.Field] = []
        if let v = s.seed { f.append(.init(key: "Seed", value: String(v))) }
        if let v = s.steps { f.append(.init(key: "Steps", value: String(v))) }
        if let v = s.cfg { f.append(.init(key: "CFG", value: ComfyRecipeView.format(v))) }
        if let v = s.samplerName { f.append(.init(key: "Sampler", value: v)) }
        if let v = s.scheduler { f.append(.init(key: "Scheduler", value: v)) }
        if let v = s.denoise { f.append(.init(key: "Denoise", value: ComfyRecipeView.format(v))) }
        if let a = s.startStep, let b = s.endStep { f.append(.init(key: "Step range", value: "\(a)–\(b)")) }
        return f
    }

    private var modelChainLine: String {
        pass.modelChain.map { step -> String in
            switch step {
            case .base(let name, let cls): return name ?? "unknown (\(cls))"
            case .lora(let name, let strength, _):
                return strength.map { "\(name) (\(ComfyRecipeView.format($0)))" } ?? name
            }
        }.joined(separator: " → ")
    }

    private var latentLine: String {
        func viaSuffix(_ via: [String]) -> String { via.isEmpty ? "" : " (\(via.joined(separator: ", ")))" }
        switch pass.latentSource {
        case .empty(let w, let h, let batch):
            var s = "Empty latent"
            if let w, let h { s += " \(w)×\(h)" }
            if let batch, batch > 1 { s += " ×\(batch)" }
            return s
        case .fromPass(let id, let via):
            return "From pass #\(id)" + (via.isEmpty ? "" : ", upscaled" + viaSuffix(via))
        case .image(_, let name, let via):
            return "Image: \(name ?? "?")" + viaSuffix(via)
        case .unknown:
            return "Latent source unknown"
        }
    }
}
```

- [ ] **Step 4: Rewrite `EmbeddedMetadataView` to switch on format**

Replace the file's contents with:

```swift
import SwiftUI

/// Displays generation metadata read directly from the image file, below the Civitai
/// "Generation Info". A1111 renders as prompt/negative/fields; ComfyUI as a recipe of
/// passes; the verbatim string is always available under a collapsible Raw disclosure.
struct EmbeddedMetadataView: View {
    let metadata: EmbeddedMetadata
    let itemID: Int
    let loadOriginalBytes: () async -> Data?

    @State private var rawCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Embedded Metadata")
                .font(.headline)
                .foregroundColor(.primary)

            switch metadata.format {
            case .automatic1111:
                if let params = metadata.parameters {
                    if let prompt = params.prompt, !prompt.isEmpty {
                        CopyablePromptView(label: "Prompt", text: prompt)
                    }
                    if let negative = params.negativePrompt, !negative.isEmpty {
                        CopyablePromptView(label: "Negative Prompt", text: negative)
                    }
                    if !params.fields.isEmpty {
                        MetadataFieldGrid(fields: params.fields)
                    }
                }
            case .comfyUI:
                if let comfy = metadata.comfy {
                    ComfyRecipeView(payload: comfy, itemID: itemID, loadOriginalBytes: loadOriginalBytes)
                }
            case .unknown:
                EmptyView()
            }

            DisclosureGroup("Raw") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            Clipboard.copy(metadata.raw)
                            withAnimation { rawCopied = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                withAnimation { rawCopied = false }
                            }
                        } label: {
                            Label(rawCopied ? "Copied" : "Copy",
                                  systemImage: rawCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(rawCopied)
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
}
```

- [ ] **Step 5: Commit (builds are verified at the end of Task 11)**

```bash
git add Diffusely/Views/MetadataFieldGrid.swift Diffusely/Utilities/DataDocument.swift Diffusely/Views/ComfyRecipeView.swift Diffusely/Views/EmbeddedMetadataView.swift
git commit -m "feat(library): ComfyUI recipe view with pass cards and export menu

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Node inspector route and view

**Files:**
- Create: `Diffusely/Views/ComfyNodeInspectorView.swift`
- Modify: `Diffusely/Views/AppNavigation.swift` (`Route` case + `RouteDestinationView` branch)

**Interfaces:**
- Consumes: `ComfyGraph`, `ComfyRecipe`, `ComfyValue.displayText`, `ComfyGraph.numericIDSort`.
- Produces: `struct ComfyInspectorPayload: Hashable { graph, recipe, title }`; `Route.comfyNodes(ComfyInspectorPayload)`; `ComfyNodeInspectorView(payload:)`.

- [ ] **Step 1: Add the route**

In `Diffusely/Views/AppNavigation.swift`, add to `enum Route`:

```swift
    /// Every node of a ComfyUI graph, grouped by the recipe pass that used it.
    case comfyNodes(ComfyInspectorPayload)
```

and to the `switch route` in `RouteDestinationView.body`:

```swift
        case .comfyNodes(let payload):
            ComfyNodeInspectorView(payload: payload)
```

- [ ] **Step 2: Write the inspector**

`Diffusely/Views/ComfyNodeInspectorView.swift`:

```swift
import SwiftUI

/// Value payload for `Route.comfyNodes`. Graph and recipe are value types, so
/// pushing them keeps the app's value-based navigation with no new pattern.
struct ComfyInspectorPayload: Hashable {
    let graph: ComfyGraph
    let recipe: ComfyRecipe
    let title: String
}

/// Every node in the graph, sectioned by the pass that used it, then
/// "Unattributed". Expanding a node shows its literal widget values verbatim
/// (where exact reproduction detail lives) and its links as `→ #id Class`.
struct ComfyNodeInspectorView: View {
    let payload: ComfyInspectorPayload
    @State private var query = ""

    var body: some View {
        List {
            ForEach(Array(payload.recipe.passes.enumerated()), id: \.element.anchor) { index, pass in
                let ids = filtered(pass.nodeIDs.sorted(by: ComfyGraph.numericIDSort))
                if !ids.isEmpty {
                    Section(sectionTitle(for: pass, index: index)) {
                        ForEach(ids, id: \.self) { id in
                            if let node = payload.graph.nodes[id] {
                                NodeRow(node: node, graph: payload.graph)
                            }
                        }
                    }
                }
            }
            let loose = filtered(payload.recipe.unattributed)
            if !loose.isEmpty {
                Section("Unattributed") {
                    ForEach(loose, id: \.self) { id in
                        if let node = payload.graph.nodes[id] {
                            NodeRow(node: node, graph: payload.graph)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Class, title, or value")
        .navigationTitle(payload.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func sectionTitle(for pass: SamplingPass, index: Int) -> String {
        payload.recipe.passes.count > 1 ? "Pass \(index + 1) — \(pass.anchorClass)" : pass.anchorClass
    }

    private func filtered(_ ids: [ComfyNodeID]) -> [ComfyNodeID] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ids }
        return ids.filter { id in
            guard let node = payload.graph.nodes[id] else { return false }
            if node.classType.lowercased().contains(q) { return true }
            if let title = node.title, title.lowercased().contains(q) { return true }
            return node.inputs.contains { input in
                if case .value(let v) = input.value { return v.displayText.lowercased().contains(q) }
                return false
            }
        }
    }
}

private struct NodeRow: View {
    let node: ComfyNode
    let graph: ComfyGraph
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(node.inputs, id: \.key) { input in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(input.key)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 90, alignment: .leading)
                    Text(text(for: input.value))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title ?? node.classType)
                    .font(.subheadline)
                Text("\(node.classType) · #\(node.id)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func text(for value: ComfyInput) -> String {
        switch value {
        case .value(let v):
            return v.displayText
        case .link(let id, let slot):
            let cls = graph.nodes[id]?.classType ?? "missing"
            return "→ #\(id) \(cls)" + (slot > 0 ? " [\(slot)]" : "")
        }
    }
}
```

- [ ] **Step 3: Build both platforms**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" | tail -10`
Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | grep -E "error:|BUILD" | tail -10`
Expected: `** BUILD SUCCEEDED **` for both. The only expected error at this point is in `LibraryDetailView.swift` (`EmbeddedMetadataView` now takes `itemID:` and `loadOriginalBytes:`) — if so, proceed to Task 12 and re-run these builds there; do not commit Task 11 until both succeed.

- [ ] **Step 4: Commit**

```bash
git add Diffusely/Views/ComfyNodeInspectorView.swift Diffusely/Views/AppNavigation.swift
git commit -m "feat(library): pushed ComfyUI node inspector grouped by pass

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Library detail wiring, sniffed container for ⌘C

**Files:**
- Modify: `Diffusely/Views/LibraryDetailView.swift`

**Interfaces:**
- Consumes: `EmbeddedMetadataView(metadata:itemID:loadOriginalBytes:)` (Task 10), `MediaContainer` (Task 1), `LibraryFileStore.readMediaAsync(itemID:plaintextExtension:)`, `LibraryVaultProvider.shared.reconcileContext()`.
- Produces: `@State private var container: MediaContainer?`; `static func readOriginalBytes(itemID:ext:) async -> Data?`.

- [ ] **Step 1: Add state and a shared bytes loader**

Below `@State private var embedded: EmbeddedMetadata?` (line 17) add:

```swift
    /// Sniffed from the decrypted bytes when embedded metadata loads, so ⌘C and
    /// export can advertise the real container instead of the cosmetic `.jpeg`.
    @State private var container: MediaContainer?
```

Add this static helper next to `loadEmbeddedMetadata`:

```swift
    /// Decrypted original bytes, off the main actor. The same path ⌘C and the
    /// embedded-metadata reader use; nil for a locked vault or unreadable media.
    private static func readOriginalBytes(itemID: Int, ext: String) async -> Data? {
        let (state, fileStore) = await LibraryVaultProvider.shared.reconcileContext()
        guard state != .locked else { return nil }
        return await fileStore.readMediaAsync(itemID: itemID, plaintextExtension: ext)
    }
```

- [ ] **Step 2: Store the container while loading embedded metadata**

Replace the body of `loadEmbeddedMetadata(for:)` with:

```swift
    private func loadEmbeddedMetadata(for metadata: LibraryItemMetadata) async {
        guard metadata.mediaType == .image else { return }
        let itemID = metadata.itemID
        let ext = (metadata.mediaFileName as NSString).pathExtension
        let result = await Task.detached(priority: .utility) { () -> (MediaContainer, EmbeddedMetadata?)? in
            guard let data = await Self.readOriginalBytes(itemID: itemID, ext: ext) else { return nil }
            return (MediaContainer.detect(data), EmbeddedMetadataReader.read(data: data))
        }.value
        container = result?.0
        embedded = result?.1
    }
```

- [ ] **Step 3: Pass the new parameters to the view**

Replace the `EmbeddedMetadataView(metadata: embedded)` call (around line 80) with:

```swift
                        if let embedded {
                            Divider()
                            let ext = (metadata.mediaFileName as NSString).pathExtension
                            let id = metadata.itemID
                            EmbeddedMetadataView(metadata: embedded, itemID: id) {
                                await Self.readOriginalBytes(itemID: id, ext: ext)
                            }
                        }
```

(Capturing `id` and `ext` by value, not `metadata`, per the project's rule on closures inside views.)

- [ ] **Step 4: Use the sniffed container for ⌘C**

In `imageItemProviders()` replace:

```swift
        let typeID = UTType(filenameExtension: ext)?.identifier ?? UTType.image.identifier
```

with:

```swift
        // Library files are named `.jpeg` regardless of content; advertise what
        // the bytes actually are once they've been sniffed.
        let typeID = container?.utType.identifier
            ?? UTType(filenameExtension: ext)?.identifier
            ?? UTType.image.identifier
```

- [ ] **Step 5: Build both platforms and run the whole unit suite**

Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" | tail -10`
Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | grep -E "error:|BUILD" | tail -10`
Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests 2>&1 | grep -E "Test Suite|passed|failed" | tail -15`
Expected: both builds succeed; every `DiffuselyTests` suite passes.

- [ ] **Step 6: Commit (and the Task 11 commit if it was deferred)**

```bash
git add Diffusely/Views/LibraryDetailView.swift
git commit -m "feat(library): wire recipe view export and advertise the sniffed container on copy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Real-workflow fixtures from the Library

**Files:**
- Create: `DiffuselyTests/Fixtures/ComfyFixtures.swift`
- Create: `DiffuselyTests/ComfyFixtureTests.swift`

**Interfaces:**
- Consumes: `ComfyGraphParser.parse`, `ComfyRecipeBuilder.build`.
- Produces: `enum ComfyFixtures` with one `static let` per real prompt JSON.

This task needs data only the user can supply. The app now has the export path, so:

- [ ] **Step 1: Collect fixtures (ask the user)**

Ask the user to open, in the built macOS app, four Library items whose Embedded Metadata section shows a ComfyUI recipe, and for each use **Export ▸ Copy API Prompt JSON**, then paste it into a file. Requested variety, each as its own paste:

1. `sdxlSinglePass` — one KSampler, a checkpoint, maybe LoRAs.
2. `hiresFix` — two samplers where the second's latent comes from the first through an upscale.
3. `flux` — a `SamplerCustomAdvanced` cluster (RandomNoise / KSamplerSelect / BasicScheduler / BasicGuider).
4. `nodeHeavy` — whichever item has the most nodes; custom nodes welcome.

If a category isn't in the Library, skip it and drop the corresponding entry below. Do not fabricate fixtures.

- [ ] **Step 2: Write the fixtures file**

`DiffuselyTests/Fixtures/ComfyFixtures.swift` — one raw multiline string per fixture, pasted verbatim:

```swift
import Foundation

/// API-format `prompt` JSON copied from real Library items via
/// Export ▸ Copy API Prompt JSON. Verbatim; do not reformat.
enum ComfyFixtures {
    static let sdxlSinglePass = #"""
    <paste>
    """#

    static let hiresFix = #"""
    <paste>
    """#

    static let flux = #"""
    <paste>
    """#

    static let nodeHeavy = #"""
    <paste>
    """#

    static let all: [(name: String, json: String)] = [
        ("sdxlSinglePass", sdxlSinglePass),
        ("hiresFix", hiresFix),
        ("flux", flux),
        ("nodeHeavy", nodeHeavy),
    ]
}
```

- [ ] **Step 3: Write the tests**

`DiffuselyTests/ComfyFixtureTests.swift`. The parameterized test asserts shape invariants that hold for any real workflow; the named tests assert what each fixture was chosen to demonstrate.

```swift
import Testing
import Foundation
@testable import Diffusely

@Suite struct ComfyFixtureTests {
    @Test(arguments: ComfyFixtures.all.map(\.name))
    func realWorkflowParsesAndSummarizes(name: String) throws {
        let json = try #require(ComfyFixtures.all.first { $0.name == name }?.json)
        let graph = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        let recipe = ComfyRecipeBuilder.build(graph)

        #expect(!recipe.passes.isEmpty, "\(name): no sampling pass found")
        #expect(recipe.unattributed.count < graph.nodes.count, "\(name): nothing was attributed")
        for pass in recipe.passes {
            #expect(!pass.modelChain.isEmpty, "\(name): pass #\(pass.anchor) has no model chain")
            #expect(pass.sampler.seed != nil || pass.sampler.steps != nil,
                    "\(name): pass #\(pass.anchor) read no sampler settings")
            #expect(!pass.positive.isEmpty || !pass.unrecognized.isEmpty,
                    "\(name): pass #\(pass.anchor) found no prompt and no unrecognized node to explain it")
            #expect(pass.nodeIDs.contains(pass.anchor))
        }
        #expect(!recipe.resources.baseModels.isEmpty || recipe.passes.contains { !$0.unrecognized.isEmpty },
                "\(name): no base model and nothing unrecognized")
    }

    @Test func sdxlSinglePassHasOnePassFromEmptyLatent() throws {
        let recipe = ComfyRecipeBuilder.build(try ComfyGraphParser.parse(prompt: ComfyFixtures.sdxlSinglePass, workflow: nil))
        #expect(recipe.passes.count == 1)
        if case .empty = recipe.passes[0].latentSource {} else { Issue.record("expected an empty latent") }
    }

    @Test func hiresFixSecondPassComesFromFirst() throws {
        let recipe = ComfyRecipeBuilder.build(try ComfyGraphParser.parse(prompt: ComfyFixtures.hiresFix, workflow: nil))
        #expect(recipe.passes.count >= 2)
        let first = recipe.passes[0].anchor
        if case .fromPass(let dep, _) = recipe.passes[1].latentSource {
            #expect(dep == first)
        } else {
            Issue.record("expected the second pass to take its latent from the first")
        }
    }

    @Test func fluxClusterReadsSettingsThroughSubNodes() throws {
        let recipe = ComfyRecipeBuilder.build(try ComfyGraphParser.parse(prompt: ComfyFixtures.flux, workflow: nil))
        let pass = try #require(recipe.passes.first { $0.anchorClass == "SamplerCustomAdvanced" })
        #expect(pass.sampler.seed != nil)
        #expect(pass.sampler.samplerName != nil)
        #expect(pass.sampler.steps != nil)
        #expect(!pass.positive.isEmpty)
    }
}
```

Remove any named test whose fixture was skipped in Step 1.

- [ ] **Step 4: Run the fixture tests**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests/ComfyFixtureTests 2>&1 | tail -30`
Expected: pass. A failure here is information, not a test bug: it means a real workflow uses a node the schema doesn't cover. Fix by adding the class to the right `ComfySchema` set (with a synthetic case in `ComfyRecipeBuilderTests` for it) — not by loosening the assertion.

- [ ] **Step 5: Commit**

```bash
git add DiffuselyTests/Fixtures/ComfyFixtures.swift DiffuselyTests/ComfyFixtureTests.swift Diffusely/Services/Media/ComfySchema.swift DiffuselyTests/ComfyRecipeBuilderTests.swift
git commit -m "test(comfy): real-workflow fixtures from the Library

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: End-to-end verification

**Files:** none new.

- [ ] **Step 1: Full unit suite on macOS**

Run: `xcodebuild test -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' -only-testing:DiffuselyTests 2>&1 | grep -E "Test Suite '.*' (passed|failed)|Executed" | tail -20`
Expected: every suite passed; `Executed N tests, with 0 failures`.

- [ ] **Step 2: Both platform builds, clean**

Run: `xcodebuild clean build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=macOS' 2>&1 | grep -E "warning:.*Comfy|error:|BUILD" | tail -10`
Run: `xcodebuild build -project Diffusely.xcodeproj -scheme Diffusely -destination 'platform=iOS Simulator,name=iPad (A16)' 2>&1 | grep -E "warning:.*Comfy|error:|BUILD" | tail -10`
Expected: `** BUILD SUCCEEDED **` twice, no warnings in the new files.

- [ ] **Step 3: Smoke run on macOS (direct launch; never the UI test target)**

Launch the built app from DerivedData (`open` the `.app` under `~/Library/Developer/Xcode/DerivedData/Diffusely-*/Build/Products/Debug/`), then ask the user to check, on one ComfyUI item and one A1111 item:

- Library detail shows **Embedded Metadata**; ComfyUI item shows the "ComfyUI workflow · N nodes · M passes" line, a Resources grid, one card per pass in the expected order, and the Raw disclosure still works.
- **All Nodes** pushes the inspector; sections match the cards; expanding a node lists inputs; search filters.
- **Export ▸ Save Original Image…** proposes `<id>.png` for a PNG item; **Save Workflow…** writes JSON that ComfyUI loads by drag-drop.
- ⌘C on a PNG item then paste into Preview yields a PNG.
- The A1111 item renders exactly as before this work.
- Opening a detail view never beachballs: watch for the grey spinner / hang class of bug (the read and parse run in `Task.detached`).

- [ ] **Step 4: Report**

State what passed, verbatim from the outputs above; list anything skipped in Task 13 and why. No push — local commits only unless the user asks.
