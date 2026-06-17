# Embedded Generation Metadata (Library)

**Date:** 2026-06-16
**Status:** Approved design, ready for implementation plan

## Problem

Civitai's API returns structured generation data (`GenerationData` / `GenerationMeta`),
but it is lossy: it flattens LoRA ordering, drops fields, and does not always match
what actually produced the image. The image files themselves often carry the original,
faithful generation record embedded in their metadata — the exact prompt with inline
`<lora:name:weight>` tags in their original order, the negative prompt, and the full
sampler/seed/model parameters.

For saved Library items we already hold the pristine original file on disk, so this
richer record is available locally at zero network cost. We want to parse it and
display it alongside the existing Civitai "Generation Info".

## Key findings (verified empirically against live Civitai originals)

- `LibrarySaveService` downloads `image.originalURL` (which uses `original=true`) and
  writes it to disk. **Only the `original=true` file carries embedded metadata;** every
  `optimized`/resized CDN variant is stripped clean. So Library items have the data
  locally; the online feed (which shows optimized variants) does not.
- The `original=true` URL uses a `.jpeg` extension cosmetically, but the **actual
  container varies** — both PNG and JPEG are common across real Civitai images.
- **Format varies by tool:**
  - **PNG** → `tEXt`/`iTXt`/`zTXt` chunks. Keys observed: `parameters` (A1111-format
    string), `Comment` (often duplicates `parameters`), and `prompt` + `workflow`
    (ComfyUI JSON graphs).
  - **JPEG** → EXIF. `UserComment` holds the prompt; Civitai's on-site Generator writes
    a generation UUID into `Software`.
  - Some images carry no real generation metadata (stripped before upload, or non-SD).
- A representative A1111 `parameters` string:
  `<prompt…> Negative prompt: <neg…> Steps: 30, Sampler: Euler a Karras, CFG scale: 4.0,
  Seed: 818544170345672, Size: 1248x1824, Clip skip: 2, Model hash: 38FB5B8E02,
  Model: Nickel Saffron Manga, Version: ComfyUI`

## Scope

**In scope**

- Library detail view (`LibraryDetailView`) only — the original is already on disk.
- Full parsing of the **A1111 `parameters` string** into structured fields.
- **Raw passthrough** for everything else (ComfyUI JSON, EXIF `UserComment`, unknown
  text) so nothing is lost even when we cannot fully structure it.
- A new "Embedded Metadata" section shown **below** the existing Civitai
  "Generation Info" — a separate, provenance-honest section, not a merge.

**Out of scope (YAGNI / deferred)**

- Structured parsing of ComfyUI node graphs (show raw JSON for now).
- NovelAI stealth-PNG (alpha-channel LSB) and other rare dialects.
- The online feed / `ImageDetailView` (the API path already serves it; embedded parse
  would require a wasteful multi-MB download).
- Video items (`.mp4` originals carry no embedded generation data).

## Components

Each unit has one purpose, a clear interface, and is independently testable.

### 1. `EmbeddedMetadata` (model)

```
struct EmbeddedMetadata {
    enum Source { case pngText(keyword: String); case exifUserComment; case exifSoftware }
    let source: Source
    let raw: String                      // verbatim chunk / EXIF value
    let parameters: GenerationParameters? // non-nil when A1111-parsed
}
```

### 2. `GenerationParameters` (model)

```
struct GenerationParameters {
    let prompt: String?
    let negativePrompt: String?
    let fields: [(key: String, value: String)]  // ORDERED: Steps, Sampler, CFG, Seed, Size, Model…
}
```

Ordering is preserved so the display matches the source file (including the order of
inline LoRA references, which live in the raw `prompt`).

### 3. `A1111ParametersParser` (pure function)

- Input: a candidate string. Output: `GenerationParameters?`.
- Detects A1111 shape (presence of the `Steps: …` parameter tail); returns nil for
  strings that are not A1111-format (e.g. a bare prompt or JSON).
- Splits into prompt / `Negative prompt:` / the trailing comma-separated key-value tail.
- Handles quoted values that contain commas (e.g. `Lora hashes: "a: 1, b: 2"`).
- No I/O; fully unit-testable.

### 4. `EmbeddedMetadataReader`

- Input: a local file URL. Output: `EmbeddedMetadata?`.
- Sniffs magic bytes:
  - **PNG** (`89 50 4E 47…`): walk chunks, reading only a **bounded header prefix** and
    stopping at the first `IDAT` (generation text chunks precede image data in practice),
    so we never load the multi-MB pixel body. Extract `tEXt`/`iTXt`/`zTXt`; pick by key
    priority `parameters` → `Comment` → `prompt`/`workflow`.
  - **JPEG/WebP**: read EXIF `UserComment` (and `Software` fallback) via `ImageIO`
    (`CGImageSourceCreateWithURL` + `CGImageSourceCopyPropertiesAtIndex`, no pixel decode).
- Runs the parser on the extracted string; returns nil when nothing usable is found.
- Note: `ImageIO` does not reliably surface arbitrary PNG `tEXt` keywords like
  `parameters`, so PNG chunk extraction is done by direct chunk parsing, not `ImageIO`.

### 5. `EmbeddedMetadataView` (SwiftUI)

- Renders below `GenerationDataView`:
  - Prompt and Negative prompt via the existing `CopyablePromptView`.
  - A caption-styled key-value grid for the remaining `fields`, matching the visual
    language of the Civitai section.
  - A collapsible **Raw** `DisclosureGroup` showing the verbatim string with a copy
    button — the reliable way to grab the exact prompt with inline `<lora:…>` tags.

## Data flow

1. `LibraryDetailView.loadMetadata()` already runs in `.task` and loads the JSON metadata.
2. After metadata loads, and only when `mediaType == .image`, start a `Task.detached`
   that:
   - `NSFileCoordinator`-reads the bounded header of `itemsDirectory/mediaFileName`,
   - runs `EmbeddedMetadataReader` (+ `A1111ParametersParser`),
   - sets `@State private var embedded: EmbeddedMetadata?` back on the main actor.
3. The `EmbeddedMetadataView` section renders only when `embedded != nil`.

## Concurrency & iCloud

Per the recurring grey-spinner lesson, all file reads happen on `Task.detached`
(never the cooperative pool) and are coordinated with `NSFileCoordinator`. If the
original is not materialized locally (iCloud-evicted), the reader returns nil and the
section silently does not appear — no blocking, no spinner, no affordance. The bounded
prefix read keeps the operation cheap even for large originals.

## Error handling

- Unreadable / missing / evicted file → reader returns nil → section hidden.
- Container not PNG/JPEG, or no recognized metadata key → reader returns nil.
- String present but not A1111-shaped → `EmbeddedMetadata` with `parameters == nil`;
  the view shows the Raw disclosure only.

## Testing (TDD)

- **`A1111ParametersParser`**: pure unit tests over fixture strings, including the
  captured live sample and a case with multiple inline `<lora:…>` tags to assert
  ordering is preserved; plus negative cases (bare prompt, JSON) returning nil.
- **`EmbeddedMetadataReader`**: tests over small committed fixture files — a PNG with a
  known `tEXt parameters` chunk, a PNG with `prompt`/`workflow` ComfyUI chunks, a JPEG
  with EXIF `UserComment`, and a file with no metadata (expect nil).
- Both targets build and pass on iOS and macOS.

## File placement

- Models: `Diffusely/Models/Civitai/` (next to `GenerationData.swift`).
- Reader/parser service: `Diffusely/Services/Media/` (next to `ImageDownsampler.swift`).
- View: `Diffusely/Views/` (or inline within `LibraryDetailView.swift` alongside the
  existing `GenerationDataView`, following the current pattern).
- Tests: `DiffuselyTests/`.
