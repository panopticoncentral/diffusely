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
            // A scalar `Infinity` / `-Infinity` is as illegal as `NaN` and just
            // as common in ComfyUI's output; without this the whole graph fails
            // to decode. `-Infinity` sanitizes to `-0`, which reads back as 0.
            .replacingOccurrences(of: "\\b-?Infinity\\b", with: "0", options: .regularExpression)
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
