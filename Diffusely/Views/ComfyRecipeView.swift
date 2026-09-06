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
            + r.loras.map { lora in .init(key: "LoRA", value: lora.strength.map { s in "\(lora.name) (\(Self.format(s)))" } ?? lora.name) }
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

            if !pass.modelChain.isEmpty {
                Text(modelChainLine)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            // Keyed by offset, not by value: a combiner wired twice to the same
            // encoder yields two identical `ConditioningText`s, which would
            // collide under `id: \.self`. Empty texts are skipped — a blank
            // negative encoder is common and renders as an empty prompt box.
            prompts(pass.positive, label: "Prompt")
            prompts(pass.negative, label: "Negative Prompt")

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

    @ViewBuilder
    private func prompts(_ texts: [ConditioningText], label: String) -> some View {
        ForEach(Array(texts.enumerated()), id: \.offset) { _, conditioning in
            if !conditioning.text.isEmpty {
                CopyablePromptView(label: label, text: conditioning.text)
            }
        }
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
