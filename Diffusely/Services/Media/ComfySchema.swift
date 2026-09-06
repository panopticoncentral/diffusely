import Foundation

/// Which of a node's inputs the builder is currently following.
enum ComfyRole {
    case model, conditioning, latent
}

/// Every node-class name `ComfyRecipeBuilder` recognizes, in one place so a new
/// node type is a one-line addition. Anything not listed here is passed through
/// on its role-matching input and reported as "unrecognized".
enum ComfySchema {
    /// How a sampler anchor's settings are laid out. The builder switches on
    /// this rather than on class names, so adding a class below is enough to
    /// make it both an anchor and readable.
    enum SamplerFamily {
        case kSampler, kSamplerAdvanced, custom, customAdvanced
    }
    static let samplerFamilies: [String: SamplerFamily] = [
        "KSampler": .kSampler, "KSamplerAdvanced": .kSamplerAdvanced,
        "SamplerCustom": .custom, "SamplerCustomAdvanced": .customAdvanced,
    ]
    /// Derived from `samplerFamilies`, never listed separately — a `let` because
    /// this is tested once per node on every output walk.
    static let samplerAnchors: Set<String> = Set(samplerFamilies.keys)
    /// Sampler-select nodes and the widget holding the name they select.
    /// A class not listed here is named by its own class name.
    static let samplerSelectNameKeys: [String: String] = [
        "KSamplerSelect": "sampler_name", "ODESamplerSelect": "solver",
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
