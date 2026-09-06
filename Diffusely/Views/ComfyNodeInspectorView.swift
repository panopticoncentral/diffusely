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
