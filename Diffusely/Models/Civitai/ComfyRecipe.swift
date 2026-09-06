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
