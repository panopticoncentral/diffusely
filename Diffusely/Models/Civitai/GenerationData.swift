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
}

struct GenerationResource: Codable {
    let modelId: Int?
    let modelName: String?
    let modelType: String?
    let versionId: Int?
    let versionName: String?
    let strength: Double?
}
