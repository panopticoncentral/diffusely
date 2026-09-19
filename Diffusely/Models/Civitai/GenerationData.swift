import Foundation

struct GenerationData: Codable {
    let type: String
    let meta: GenerationMeta?
    let resources: [GenerationResource]?
}

struct GenerationMeta: Codable {
    let prompt: String?
    let negativePrompt: String?
    let cfgScale: Double?
    let steps: Int?
    let sampler: String?
    let seed: Int?
    let clipSkip: Int?
    /// Civitai's generation ecosystem (for example "Krea 2" or "SDXL 1.0").
    /// This can be present even when the API omits an explicit Checkpoint
    /// resource, which makes it a useful conservative fallback for Library
    /// grouping.
    let baseModel: String?

    init(
        prompt: String?, negativePrompt: String?, cfgScale: Double?, steps: Int?,
        sampler: String?, seed: Int?, clipSkip: Int?, baseModel: String? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.cfgScale = cfgScale
        self.steps = steps
        self.sampler = sampler
        self.seed = seed
        self.clipSkip = clipSkip
        self.baseModel = baseModel
    }
}

struct GenerationResource: Codable {
    let modelId: Int?
    let modelName: String?
    let modelType: String?
    let versionId: Int?
    let versionName: String?
    /// Ecosystem the resource was built for. In particular, a lone LoRA often
    /// carries this even when Civitai does not list the implicit base
    /// checkpoint used by Remix.
    let baseModel: String?
    let strength: Double?

    init(
        modelId: Int?, modelName: String?, modelType: String?, versionId: Int?,
        versionName: String?, baseModel: String? = nil, strength: Double?
    ) {
        self.modelId = modelId
        self.modelName = modelName
        self.modelType = modelType
        self.versionId = versionId
        self.versionName = versionName
        self.baseModel = baseModel
        self.strength = strength
    }
}
