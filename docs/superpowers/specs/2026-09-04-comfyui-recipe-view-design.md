# ComfyUI Recipe View (Library)

**Date:** 2026-09-04
**Status:** Approved design, ready for implementation plan

## Problem

Library items that were generated off-site with ComfyUI carry their full node graph
in the original file (`prompt` + `workflow` PNG `tEXt` chunks, or the same JSON in
EXIF `UserComment` for JPEG/WebP saves). Today `EmbeddedMetadataReader` extracts
that text correctly, but the only parser is `A1111ParametersParser`, which returns
nil for graph JSON. The result is that ComfyUI items show a raw JSON blob under the
"Raw" disclosure and nothing else — while the Civitai "Generation Info" above it is
often thin for exactly these items (no hash-matched checkpoint, `Model` a raw
filename), because Civitai never matched their resources.

The goal is comprehension and reuse: understand how an image was put together —
which passes, in what order, fed by what — and be able to lift elements (prompts,
LoRA stacks, sampler settings) or load the workflow back into ComfyUI.

This is deliberately **not** "port Civitai's parser." Civitai's `comfy.metadata.ts`
flattens the graph into an A1111-shaped record (`a1111Compatibility()` even renames
the sampler) because its purpose is attribution and remix-by-resubmission; it stashes
the raw graph back into `meta.comfy` precisely because that flattening is lossy. The
flat summary is already on screen as Generation Info. The value here is in what that
projection discards: structure.

## Key findings

- Established in the 2026-06-16 embedded-metadata spec and re-verified: the saved
  bytes are the `original=true` file, so a ComfyUI PNG comes back as PNG bytes
  despite the `.jpeg` filename. The reader sniffs magic bytes, so the PNG path works.
- Civitai's parser also reads Comfy JSON out of EXIF `UserComment`, and a WebP
  variant where the JSON sits in the `Model` tag prefixed with `prompt:`. Both must
  be handled.
- ComfyUI emits JSON that `JSONSerialization` rejects (`NaN`, `Infinity`). Civitai's
  `cleanBadJson` handles this; port it.
- The `prompt` chunk is the resolved API-format node dict (semantics). The
  `workflow` chunk is the litegraph UI graph (positions, titles) and is the file
  ComfyUI loads by drag-drop. Both are needed; today the reader keeps only one.
- The on-macOS ⌘C item provider streams the original bytes but advertises the
  UTType from the `.jpeg` filename, so a PNG goes on the pasteboard labelled
  `public.jpeg`. iOS has no export path at all.
- Civitai's Comfy test fixtures are near-empty (54 lines, engine-flag tests only).
  Real fixtures must come from the user's own Library.
- Parsed data stays **view-only**. Nothing feeds the sidecar or the SwiftData index
  in this work (decided; feeding `checkpointName` is a follow-up with its own
  questions about how raw filenames group against Civitai-matched names).

## Scope

In scope:

1. Reader: retain every recognized text field; detect container and format;
   route EXIF-carried Comfy JSON.
2. `ComfyGraph` model and parser (from `prompt`, enriched by `workflow`).
3. `ComfyRecipe` builder: topology-driven pass extraction.
4. Inline recipe view; pushed node inspector; export (workflow JSON, original file).
5. Fix the macOS ⌘C UTType to match the sniffed container.
6. Unit tests for reader, parser, builder; real-workflow fixtures.

Out of scope (deferred, each its own spec):

- A 2D canvas rendering of nodes and wires (positions are read but not stored).
- Feeding parsed checkpoint/LoRA names into the Library index or sidecars.
- Any format beyond A1111 (existing) and ComfyUI. SwarmUI/Fooocus/InvokeAI are not
  parsed; they surface as `.unknown` with Raw available.
- Rendering A1111 items through the recipe model.

## Section 1 — Extraction layer

`EmbeddedMetadata` becomes an envelope of everything recognized, not one chunk:

```swift
struct EmbeddedMetadata: Equatable {
    /// Every recognized text field keyed by source name.
    /// PNG: the tEXt keyword. EXIF: "UserComment", and "Model" for the WebP variant.
    let fields: [String: String]
    let container: MediaContainer          // .png, .jpeg, .webp, .other
    let format: Format                     // .automatic1111, .comfyUI, .unknown
    /// Verbatim text for the Raw disclosure. A1111: the parameters string.
    /// Comfy: the `workflow` JSON if present (the loadable one), else `prompt`.
    let raw: String
    let parameters: GenerationParameters?  // A1111 only; parser unchanged
    let comfy: ComfyPayload?               // non-nil iff format == .comfyUI
}

struct ComfyPayload: Equatable {
    let promptJSON: String?
    let workflowJSON: String?
    let graph: ComfyGraph?                 // nil on parse failure
    let recipe: ComfyRecipe?               // nil on parse failure
    let error: ComfyParseError?
}

enum MediaContainer { case png, jpeg, webp, other }
```

`MediaContainer.detect(_ data: Data)` sniffs PNG (`89 50 4E 47…`), JPEG (`FF D8`),
WebP (`RIFF….WEBP`). It is the one sniffer, shared by the reader and the export
path.

**Reader changes** (`EmbeddedMetadataReader`):

- `pngTextChunks` is unchanged. The PNG entry point keeps **all** chunks in
  `fields` instead of taking the first match of a priority list.
- The EXIF path reads `UserComment` and, when present, `Model`. If `UserComment`
  decodes to a string that looks like Comfy JSON, or `Model` begins with `prompt:`,
  the Comfy detector sees them as `prompt`/`workflow` fields.
- **Format detection** is an ordered `canParse` list, first match wins:
  1. `.automatic1111` — a `parameters` (or `Comment`, or `UserComment`) field that
     `A1111ParametersParser.parse` accepts.
  2. `.comfyUI` — a `prompt` or `workflow` field (from PNG or routed from EXIF)
     whose JSON is a top-level object with at least one value carrying `class_type`
     (`prompt`) or a `nodes` array (`workflow`).
  3. `.unknown` — anything else with at least one non-empty field. No fields → the
     reader returns nil as today.
- **UserComment decoding.** Today the reader relies on ImageIO returning
  `kCGImagePropertyExifUserComment` as a decoded `String`. Civitai's
  `decodeUserComment` (encoding-helpers.ts:50) handles an 8-byte charset header
  (`ASCII\0\0\0`, `UNICODE\0`, `UTF8\0\0\0\0`), UTF-16 BE/LE with and without BOM,
  and a null-parity heuristic for BOM-less UTF-16. The port is gated on evidence:
  implement the header + BOM branches, and add the parity heuristic only if a real
  fixture from the Library demonstrates ImageIO mishandles it. The raw bytes are
  obtained from the EXIF dictionary's data representation when the string form is
  empty or contains replacement characters.
- Parsing the graph and building the recipe run inside `read(data:)` /
  `read(fileURL:)` so callers receive a finished value. Both entry points keep their
  existing off-main-actor contract.

`A1111ParametersParser` is untouched. Existing A1111 behaviour is preserved
byte-for-byte: same fields, same `raw`, same `parameters`.

## Section 2 — ComfyUI graph model and parser

Pure value types. No SwiftUI, no I/O, no knowledge of what any node class means.

```swift
typealias ComfyNodeID = String            // Comfy uses "3", "12", … as keys

struct ComfyGraph: Equatable, Hashable {
    let nodes: [ComfyNodeID: ComfyNode]
    /// Nodes no other node links to. Usually one SaveImage; may be several.
    let outputs: [ComfyNodeID]
    /// Links whose target id does not exist in `nodes`.
    let danglingLinks: [DanglingLink]
}

struct DanglingLink: Equatable, Hashable {
    let from: ComfyNodeID
    let input: String
}

struct ComfyNode: Equatable, Hashable {
    let id: ComfyNodeID
    let classType: String                 // "KSampler", "LoraLoader", …
    let title: String?                    // `_meta.title` from workflow, if any
    let inputs: [ComfyNodeInput]          // ordered by key for stable display
}

struct ComfyNodeInput: Equatable, Hashable {
    let key: String
    let value: ComfyInput
}

enum ComfyInput: Equatable, Hashable {
    case value(ComfyValue)                // string, number, bool, null, array, object
    case link(node: ComfyNodeID, slot: Int)
}

enum ComfyParseError: Error, Equatable {
    case malformedJSON
    case notAGraph                        // parsed, but no node carries class_type
}
```

`ComfyGraphParser.parse(prompt: String, workflow: String?) throws -> ComfyGraph`:

1. **Decode** `prompt` with `JSONSerialization`. If that throws, apply
   `cleanBadJson` — `[NaN]` → `[]`, `\bNaN\b` → `0`, `[Infinity]` → `[]` — and
   retry once. Well-formed input is never rewritten. Second failure →
   `.malformedJSON`.
2. **Typed walk.** Top-level must be an object. Each value that is an object with a
   string `class_type` becomes a `ComfyNode`; entries without one are skipped. If no
   node results → `.notAGraph`.
3. **Link disambiguation.** An input value that is a two-element array whose first
   element is a string and second a number becomes `.link`; everything else is
   `.value`. This matches Civitai's rule at comfy.metadata.ts:157. Links to a
   non-existent node are kept as `.link` and recorded in `danglingLinks`; not an
   error.
4. **`workflow` enrichment** is best-effort. If it parses and has a `nodes` array,
   `_meta.title` / `title` is copied onto the matching `ComfyNode` by id. If it
   fails to parse, the graph still builds. Positions are neither stored nor
   validated (deferred canvas).
5. **Outputs** = every node id that appears as no other node's link target.

## Section 3 — Recipe builder

`ComfyRecipeBuilder.build(_ graph: ComfyGraph) -> ComfyRecipe`. Pure and
deterministic; the only place that knows what node classes mean. All class-name
knowledge lives in one table, `ComfySchema`, so adding a node type is a one-line
change.

```swift
struct ComfyRecipe: Equatable, Hashable {
    let passes: [SamplingPass]            // execution order
    let resources: ResourceSummary        // union across passes, de-duplicated by name
    let unattributed: [ComfyNodeID]       // never reached by any walk
}

struct SamplingPass: Equatable, Hashable {
    let anchor: ComfyNodeID               // the sampler node
    let anchorClass: String
    let sampler: SamplerSettings          // seed, steps, cfg, samplerName, scheduler,
                                          // denoise, startStep, endStep — all optional
    let modelChain: [ModelStep]           // .base(name, class) first, then .lora(name,
                                          // strengthModel, strengthClip) in apply order
    let positive: [ConditioningText]      // (text, nodeID); several if combined
    let negative: [ConditioningText]
    let latentSource: LatentSource
    let modifiers: [String]               // recognized pass-through classes seen
    let unrecognized: [ComfyNodeID]       // passed through blind on this pass
    let nodeIDs: Set<ComfyNodeID>         // everything attributed here (inspector)
}

enum LatentSource: Equatable, Hashable {
    case empty(width: Int?, height: Int?, batch: Int?)
    case fromPass(ComfyNodeID, via: [String])   // e.g. ["LatentUpscaleBy"]
    case image(loadNode: ComfyNodeID, name: String?, via: [String])
    case unknown
}

struct SamplerSettings: Equatable, Hashable {
    let seed: Int?
    let steps: Int?
    let cfg: Double?
    let samplerName: String?
    let scheduler: String?
    let denoise: Double?
    let startStep: Int?
    let endStep: Int?
}

enum ModelStep: Equatable, Hashable {
    case base(name: String?, classType: String)
    case lora(name: String, strengthModel: Double?, strengthClip: Double?)
}

struct ConditioningText: Equatable, Hashable {
    let text: String
    let nodeID: ComfyNodeID
}

struct LoraResource: Equatable, Hashable {
    let name: String
    let strength: Double?                 // max strengthModel seen across passes
}

struct ResourceSummary: Equatable, Hashable {
    let baseModels: [String]
    let loras: [LoraResource]
    let vaes: [String]
    let controlNets: [String]
    let upscaleModels: [String]
}
```

### The walk

From each output, DFS backwards over links.

**Output plumbing.** Everything traversed before reaching the first sampler anchor
— `SaveImage`, `PreviewImage`, `VAEDecode`, the `VAELoader` on its `vae` input,
pixel-space upscalers (`ImageUpscaleWithModel`, `ImageScale*`), and their loaders —
is attributed to that anchor's pass.

**Anchors** (from `ComfySchema.samplerAnchors`): `KSampler`, `KSamplerAdvanced`,
`SamplerCustom`, `SamplerCustomAdvanced`. For `SamplerCustomAdvanced` the settings
resolve through sub-inputs:
`noise` → `RandomNoise.noise_seed`; `sampler` → `KSamplerSelect.sampler_name` /
`ODESamplerSelect.solver`; `sigmas` → `BasicScheduler` (`steps`, `scheduler`,
`denoise`); `guider` → `BasicGuider` (conditioning only) or `CFGGuider`
(`cfg`, positive, negative).

**Three role walks per anchor:**

- `model` → `LoraLoader` / `LoraLoaderModelOnly` appends a `.lora` step and
  continues on its `model` input. Known modifiers (`ModelSamplingFlux`,
  `ModelSamplingSD3`, `FreeU`, `FreeU_V2`, `PatchModelAddDownscale`, …) append to
  `modifiers` and continue. Stops at a loader (`CheckpointLoaderSimple`,
  `UNETLoader`, `UnetLoaderGGUF`, `ImageOnlyCheckpointLoader`, …) as `.base`.
- `positive` / `negative` → `CLIPTextEncode` yields text from its `text` widget.
  `ConditioningCombine`, `ConditioningConcat`, `ConditioningAverage` recurse into
  both sides. `ControlNetApply` / `ControlNetApplyAdvanced` records the ControlNet
  (via `control_net` → `ControlNetLoader.control_net_name`) and continues on its
  conditioning input. `FluxGuidance` records `guidance` as `cfg` (when the sampler
  has none) and continues.
- `latent_image` (or `latent` for custom samplers) → `EmptyLatentImage` /
  `EmptySD3LatentImage` → `.empty(width, height, batch)`. `LatentUpscale` /
  `LatentUpscaleBy` push their class onto `via` and continue on `samples`.
  `VAEEncode` follows `pixels`: `LoadImage` → `.image`; a pixel upscaler pushes
  onto `via` and continues; `VAEDecode` follows `samples`. A `VAEDecode` whose
  `samples` reaches another anchor → `.fromPass(thatAnchor, via:)`.

**Widget links.** A widget value that is a `.link` (to `PrimitiveNode`, a
string-constant node, etc.) is resolved by following `value` / `string` / `text`
inputs with a depth cap of 5 — the shape of Civitai's `resolveResourceName`.

**Unknown classes are transparent.** A node not in `ComfySchema` is passed through
on the input whose name matches the current role (`model`, `conditioning`,
`positive`, `negative`, `latent`, `latent_image`, `samples`, `pixels`) and is added
to the pass's `unrecognized`. If no such input exists the walk stops: the model
chain ends in `.base(name: nil, class: theClass)`, conditioning yields nothing,
latent is `.unknown`. A custom node never breaks the recipe; it makes it
incomplete and says so.

**Ordering.** Passes are topologically sorted — a pass whose latent source is
`.fromPass(x)` follows `x`. Ties break by numeric node id, then string.

**Attribution.** Every node visited during a pass's walks joins its `nodeIDs`. A
node shared by two passes (one checkpoint loader feeding both) belongs to both.
Any node in no pass is `unattributed`.

**Safety.** A visited set per walk and a depth cap (500) so malformed cycles
terminate; dangling links resolve to nothing.

## Section 4 — Views and export

### Placement

`EmbeddedMetadataView` switches on `metadata.format`:

- `.automatic1111` — renders exactly as today.
- `.comfyUI` — renders `ComfyRecipeView(payload:)` inline, in the detail scroll,
  below Generation Info and above the Raw disclosure. If `payload.recipe` is nil,
  one line: "Couldn't read this ComfyUI workflow." Raw stays below it.
- `.unknown` — nothing structured.

The Raw disclosure and its Copy button are unchanged for every format.

### `ComfyRecipeView`

Top to bottom:

1. **Resources** — base models, LoRAs with strength, VAE, ControlNets, upscalers,
   using the existing `fieldGrid` style. Names are text-selectable.
2. **Passes** — one card per `SamplingPass` in order. Numbered ("Pass 1", "Pass 2")
   only when there is more than one. Each card:
   - sampler settings as a compact grid: seed · steps · cfg · sampler · scheduler ·
     denoise (omit nil entries; show start/end step only when present)
   - the model chain on one line: `base → lora (0.8) → lora (0.6)`
   - Positive and Negative through the existing `CopyablePromptView`
   - latent source as a sentence: "Empty 1024×1024", "From pass 1, upscaled
     (LatentUpscaleBy)", "Image: input.png"
   - modifiers as a caption line
   - "via N unrecognized nodes" when `unrecognized` is non-empty
3. **Actions** — an "All Nodes" button and an export `Menu`.

### Inspector

Pushed as `Route.comfyNodes(ComfyInspectorPayload)`, where the payload is the
`ComfyGraph`, the `ComfyRecipe`, and the item's display title — all value types,
`Hashable`, so this follows the app's value-routed navigation with no new pattern.

Content is a `List`:

- one section per pass, titled as on the card, listing that pass's `nodeIDs` in
  numeric id order
- a final "Unattributed" section
- a node row: title (from `_meta.title`, else class), class type, `#id`
- expanding a row shows its inputs: literal widget values verbatim (this is where
  exact reproduction detail lives), links as `→ #12 CLIPTextEncode`
- a search field filtering on class, title, or any literal value

### Export

A `Menu` on the recipe view:

- **Copy workflow JSON** — `workflowJSON` verbatim; if absent, `promptJSON`,
  labelled "Copy workflow JSON (API format)".
- **Save workflow…** — `<itemID>.workflow.json` when `workflowJSON` exists;
  otherwise `<itemID>.api.json` containing `promptJSON`.
- **Save original image…** — the decrypted original bytes with the container
  sniffed by `MediaContainer.detect`, so the suggested filename and UTType match
  (`<itemID>.png` for a PNG). This is the file ComfyUI loads by drop.

Both saves use SwiftUI `.fileExporter`, which is one API on iOS and macOS. Bytes
are read through `LibraryFileStore.readMediaAsync` off the main actor, as the
existing ⌘C provider does.

The macOS ⌘C `imageItemProviders()` gets the same sniff so the registered
UTType matches the bytes. Two-line change in a function this work already touches.

### Loading

`LibraryDetailView.loadEmbeddedMetadata` is unchanged in shape: one
`Task.detached` that reads bytes and calls `EmbeddedMetadataReader.read(data:)`.
Graph parsing and recipe building now happen inside that call, so the view receives
a finished `EmbeddedMetadata`. Nothing new runs on the main actor.

Both the iOS and macOS targets must build; no platform-conditional UI beyond what
`.fileExporter` requires.

## Section 5 — Testing

Swift Testing, matching existing suites. Three pure layers; no SwiftUI or vault in
unit tests.

**Reader** (`EmbeddedMetadataReaderTests`, extended, reusing `makePNG`):
- all chunks retained, not first-match
- A1111 wins over Comfy when both `parameters` and `prompt` are present
- `prompt` alone and `workflow` alone both yield `.comfyUI`
- EXIF `UserComment` carrying `{"prompt":…}` routes to Comfy
- `Model: prompt:{…}` routes to Comfy
- `raw` prefers `workflow` over `prompt`
- existing A1111 cases pass unchanged
- one case per UserComment charset branch that a real fixture demonstrates

**Graph parser** (`ComfyGraphParserTests`):
- `["12", 0]` → `.link`; `[1, 2]` and `["a", "b"]` → `.value`
- dangling link recorded, not thrown
- `NaN` sanitized only after a clean decode fails; clean input round-trips verbatim
- `_meta.title` enrichment from `workflow`
- unparseable `workflow` does not fail the graph
- `.notAGraph` for JSON with no `class_type`; `.malformedJSON` for garbage
- outputs are exactly the unconsumed nodes

**Recipe builder** (`ComfyRecipeBuilderTests`), each a small hand-built graph:
- single `KSampler` txt2img: one pass, `.empty`, chain is just the checkpoint
- two stacked LoRAs: apply order and both strengths preserved
- hires-fix: two passes, second is `.fromPass(first, via: ["LatentUpscaleBy"])`,
  ordering correct
- img2img: `.image` through `VAEEncode` → `LoadImage`
- `SamplerCustomAdvanced` Flux cluster: seed / sampler / steps / cfg each from the
  right sub-node; `FluxGuidance` in modifiers
- `ConditioningCombine`: both texts in `positive`
- ControlNet in the conditioning chain: recorded in resources, text still reached
- prompt text via `PrimitiveNode` link: resolved; depth cap holds
- unknown class with a `model` input: chain continues, node in `unrecognized`
- unknown class with no matching input: chain ends in an unknown base, no crash
- cycle: terminates
- attribution: `SaveImage` / `VAEDecode` on their pass; a loader shared by two
  passes appears in both; a disconnected node is `unattributed`

**Real fixtures.** Three to five actual `prompt`/`workflow` pairs from the user's
Library as test resources: an SDXL single pass, a hires-fix, a Flux, and the most
node-heavy one available. Tests assert recipe *shape* (pass count, latent source
kinds, LoRA count, that a base model was found), not exact strings, so they stay
stable. Obtaining them is a plan task (via the shipped reader, or a one-off
`original=true` fetch of known ids), not a blocker for the synthetic suite.

**Views**: no unit tests. Verified by building both targets and opening several
Comfy items. The macOS UI test suite is not run.

## Files

New:
- `Diffusely/Models/Civitai/ComfyGraph.swift` — Section 2 types
- `Diffusely/Models/Civitai/ComfyRecipe.swift` — Section 3 types
- `Diffusely/Services/Media/ComfyGraphParser.swift`
- `Diffusely/Services/Media/ComfyRecipeBuilder.swift`
- `Diffusely/Services/Media/ComfySchema.swift` — the class-name table
- `Diffusely/Services/Media/MediaContainer.swift`
- `Diffusely/Views/ComfyRecipeView.swift`
- `Diffusely/Views/ComfyNodeInspectorView.swift`
- `DiffuselyTests/ComfyGraphParserTests.swift`
- `DiffuselyTests/ComfyRecipeBuilderTests.swift`
- `DiffuselyTests/Fixtures/Comfy/*.json`

Modified:
- `Diffusely/Models/Civitai/EmbeddedMetadata.swift` — envelope shape (Section 1)
- `Diffusely/Services/Media/EmbeddedMetadataReader.swift` — all-chunks, format
  detection, EXIF routing, UserComment decode, parse-in-read
- `Diffusely/Views/EmbeddedMetadataView.swift` — switch on format
- `Diffusely/Views/LibraryDetailView.swift` — ⌘C UTType sniff; export bytes helper
- `Diffusely/Views/AppNavigation.swift` — `Route.comfyNodes`
- `DiffuselyTests/EmbeddedMetadataReaderTests.swift` — extended
