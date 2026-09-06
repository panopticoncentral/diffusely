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
            // A fresh visited set per role walk: one encoder legitimately feeds
            // both positive and negative, so the sets must not be shared.
            if let pos = starts.positive {
                var seen = Set<ComfyNodeID>()
                draft.positive = walkConditioning(from: pos, negative: false, into: &draft, seen: &seen)
            }
            if let neg = starts.negative {
                var seen = Set<ComfyNodeID>()
                draft.negative = walkConditioning(from: neg, negative: true, into: &draft, seen: &seen)
            }
            if let latent = linkTarget(node, "latent_image") ?? linkTarget(node, "latent") {
                draft.latentSource = walkLatent(from: latent, into: &draft)
            }
            drafts[anchor] = draft
        }

        mutating func readSamplerSettings(_ node: ComfyNode, into draft: inout PassDraft) {
            switch ComfySchema.samplerFamilies[node.classType] {
            case .kSampler:
                draft.sampler.seed = seedWidget(node, "seed", &draft)
                draft.sampler.steps = intWidget(node, "steps", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                draft.sampler.samplerName = stringWidget(node, "sampler_name", &draft)
                draft.sampler.scheduler = stringWidget(node, "scheduler", &draft)
                draft.sampler.denoise = doubleWidget(node, "denoise", &draft)
            case .kSamplerAdvanced:
                draft.sampler.seed = seedWidget(node, "noise_seed", &draft)
                draft.sampler.steps = intWidget(node, "steps", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                draft.sampler.samplerName = stringWidget(node, "sampler_name", &draft)
                draft.sampler.scheduler = stringWidget(node, "scheduler", &draft)
                draft.sampler.startStep = intWidget(node, "start_at_step", &draft)
                draft.sampler.endStep = intWidget(node, "end_at_step", &draft)
            case .custom:
                draft.sampler.seed = seedWidget(node, "noise_seed", &draft)
                draft.sampler.cfg = doubleWidget(node, "cfg", &draft)
                if let s = linkTarget(node, "sampler") { readSamplerSelect(s, into: &draft) }
                if let s = linkTarget(node, "sigmas") { readScheduler(s, into: &draft) }
            case .customAdvanced:
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

        /// A select node listed in `ComfySchema.samplerSelectNameKeys` carries the
        /// name in a widget; the dedicated `SamplerEulerAncestral` style nodes
        /// don't, and are named by their class.
        mutating func readSamplerSelect(_ id: ComfyNodeID, into draft: inout PassDraft) {
            guard let node = graph.nodes[id] else { return }
            draft.nodeIDs.insert(id)
            if let key = ComfySchema.samplerSelectNameKeys[node.classType] {
                draft.sampler.samplerName = stringWidget(node, key, &draft)
            } else {
                draft.sampler.samplerName = node.classType
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
            guard ComfySchema.samplerFamilies[node.classType] == .customAdvanced else {
                return linkTarget(node, "model")
            }
            guard let g = linkTarget(node, "guider"), let guider = graph.nodes[g] else { return nil }
            draft.nodeIDs.insert(g)
            return linkTarget(guider, "model")
        }

        /// `BasicGuider` has one `conditioning`; `CFGGuider` / `DualCFGGuider` have
        /// positive/negative and carry the cfg.
        mutating func conditioningStarts(_ node: ComfyNode, into draft: inout PassDraft)
            -> (positive: ComfyNodeID?, negative: ComfyNodeID?) {
            guard ComfySchema.samplerFamilies[node.classType] == .customAdvanced else {
                return (linkTarget(node, "positive"), linkTarget(node, "negative"))
            }
            guard let g = linkTarget(node, "guider"), let guider = graph.nodes[g] else { return (nil, nil) }
            draft.nodeIDs.insert(g)
            if draft.sampler.cfg == nil { draft.sampler.cfg = doubleWidget(guider, "cfg", &draft) }
            return (linkTarget(guider, "positive") ?? linkTarget(guider, "conditioning"),
                    linkTarget(guider, "negative"))
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
                } else if let next = passThrough(node, role: .model) {
                    draft.noteUnrecognized(id)
                    current = next
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

        /// `seen` is the visited set for THIS role walk. The combiner branch fans
        /// out over every link input, so without it a cycle through a combiner (or
        /// through unrecognized pass-through nodes) is exponential in `depth` —
        /// a hang, not just a slow walk. The depth cap stays as a second bound.
        mutating func walkConditioning(from start: ComfyNodeID, negative: Bool,
                                       into draft: inout PassDraft,
                                       seen: inout Set<ComfyNodeID>,
                                       depth: Int = 0) -> [ConditioningText] {
            guard depth < ComfySchema.walkDepthCap, seen.insert(start).inserted,
                  let node = graph.nodes[start] else { return [] }
            draft.nodeIDs.insert(start)
            let cls = node.classType

            if ComfySchema.textEncoders.contains(cls) {
                return [ConditioningText(text: encodedText(node, &draft), nodeID: start)]
            }
            if ComfySchema.conditioningCombiners.contains(cls) {
                var texts: [ConditioningText] = []
                for input in node.inputs {
                    guard case .link(let target, _) = input.value else { continue }
                    texts += walkConditioning(from: target, negative: negative, into: &draft, seen: &seen, depth: depth + 1)
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
                return walkConditioning(from: next, negative: negative, into: &draft, seen: &seen, depth: depth + 1)
            }
            if ComfySchema.guidanceModifiers.contains(cls) {
                if draft.sampler.cfg == nil { draft.sampler.cfg = doubleWidget(node, "guidance", &draft) }
                if !draft.modifiers.contains(cls) { draft.modifiers.append(cls) }
                guard let next = linkTarget(node, "conditioning") else { return [] }
                return walkConditioning(from: next, negative: negative, into: &draft, seen: &seen, depth: depth + 1)
            }
            if ComfySchema.conditioningPassThrough.contains(cls) {
                if !draft.modifiers.contains(cls) { draft.modifiers.append(cls) }
                guard let next = linkTarget(node, "conditioning") else { return [] }
                return walkConditioning(from: next, negative: negative, into: &draft, seen: &seen, depth: depth + 1)
            }
            draft.noteUnrecognized(start)
            guard let next = passThrough(node, role: .conditioning, negative: negative) else { return [] }
            return walkConditioning(from: next, negative: negative, into: &draft, seen: &seen, depth: depth + 1)
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
                guard let next = passThrough(node, role: .latent) else { return .unknown }
                current = next
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
