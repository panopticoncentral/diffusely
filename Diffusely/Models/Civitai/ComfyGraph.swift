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
