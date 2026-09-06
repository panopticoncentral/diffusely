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
        // Assumes the "Negative prompt:" marker does not appear inside the positive
        // prompt (matches A1111's line-anchored behavior).
        if let negRange = head.range(of: "Negative prompt:") {
            let p = String(head[..<negRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = p.isEmpty ? nil : p
            let n = String(head[negRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = n.isEmpty ? nil : n
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
