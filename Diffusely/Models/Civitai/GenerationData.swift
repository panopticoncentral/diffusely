import Foundation

struct GenerationData: Codable {
    let type: String
    let meta: GenerationMeta?
    let resources: [GenerationResource]?

    /// Some uploaded images name the checkpoint only by version ID in their
    /// raw parameters, even when Civitai's resolved `resources` omits it.
    var rawCheckpointVersionID: Int? {
        rawCheckpointReferences.first(where: { ($0.modelVersionId ?? 0) > 0 })?.modelVersionId
    }

    /// A raw resource may already carry the checkpoint's display name. Keep
    /// that exact name instead of requiring a live version lookup.
    var namedRawCheckpointResource: GenerationResource? {
        rawCheckpointReferences.compactMap(\.namedCheckpointResource).first
    }

    private var rawCheckpointReferences: [CivitaiResourceReference] {
        (meta?.civitaiResources ?? []).filter(\.isCheckpoint)
            + Self.checkpointReferences(in: meta?.prompt)
            + Self.checkpointReferences(in: meta?.negativePrompt)
    }

    static func checkpointID(in text: String?) -> Int? {
        checkpointReferences(in: text).first(where: { ($0.modelVersionId ?? 0) > 0 })?.modelVersionId
    }

    static func checkpointReferences(in text: String?) -> [CivitaiResourceReference] {
        guard let text,
              let marker = text.range(of: "Civitai resources:", options: .caseInsensitive),
              let start = text[marker.upperBound...].firstIndex(of: "[")
        else { return [] }
        // Model names can themselves contain brackets (for example "[GP]"),
        // so the first `]` is not necessarily the end of this JSON array.
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        for index in text[start...].indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        guard let end else { return [] }
        let json = String(text[start...end])
        return ((try? JSONDecoder().decode([CivitaiResourceReference].self, from: Data(json.utf8))) ?? [])
            .filter(\.isCheckpoint)
    }

    func addingResolvedCheckpoint(_ checkpoint: GenerationResource) -> GenerationData {
        var updated = resources ?? []
        if let blank = updated.firstIndex(where: {
            $0.modelType?.caseInsensitiveCompare("Checkpoint") == .orderedSame
                && ($0.modelName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && ($0.versionId == nil || $0.versionId == checkpoint.versionId)
        }) {
            updated[blank] = checkpoint
        } else {
            updated.append(checkpoint)
        }
        return GenerationData(type: type, meta: meta, resources: updated)
    }

    func addingRawCheckpointVersionID(_ versionID: Int) -> GenerationData {
        let old = meta
        let reference = CivitaiResourceReference(type: "checkpoint", modelVersionId: versionID)
        let updatedMeta = GenerationMeta(
            prompt: old?.prompt, negativePrompt: old?.negativePrompt,
            cfgScale: old?.cfgScale, steps: old?.steps, sampler: old?.sampler,
            seed: old?.seed, clipSkip: old?.clipSkip, baseModel: old?.baseModel,
            civitaiResources: (old?.civitaiResources ?? []) + [reference]
        )
        return GenerationData(type: type, meta: updatedMeta, resources: resources)
    }
}

struct CivitaiResourceReference: Codable {
    let type: String?
    let modelVersionId: Int?
    let modelName: String?
    let modelVersionName: String?

    init(type: String?, modelVersionId: Int?, modelName: String? = nil, modelVersionName: String? = nil) {
        self.type = type
        self.modelVersionId = modelVersionId
        self.modelName = modelName
        self.modelVersionName = modelVersionName
    }

    var isCheckpoint: Bool { type?.caseInsensitiveCompare("checkpoint") == .orderedSame }

    var namedCheckpointResource: GenerationResource? {
        guard isCheckpoint,
              let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelName.isEmpty else { return nil }
        return GenerationResource(
            modelId: nil, modelName: modelName, modelType: "Checkpoint",
            versionId: (modelVersionId ?? 0) > 0 ? modelVersionId : nil,
            versionName: modelVersionName, strength: nil
        )
    }
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
    /// Raw version references may be supplied separately from the prompt.
    let civitaiResources: [CivitaiResourceReference]?

    private enum CodingKeys: String, CodingKey {
        case prompt, negativePrompt, cfgScale, steps, sampler, seed, clipSkip
        case baseModel, civitaiResources
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt)
        negativePrompt = try values.decodeIfPresent(String.self, forKey: .negativePrompt)
        cfgScale = try values.decodeIfPresent(Double.self, forKey: .cfgScale)
        steps = try values.decodeIfPresent(Int.self, forKey: .steps)
        sampler = try values.decodeIfPresent(String.self, forKey: .sampler)
        seed = try values.decodeIfPresent(Int.self, forKey: .seed)
        clipSkip = try values.decodeIfPresent(Int.self, forKey: .clipSkip)
        baseModel = try values.decodeIfPresent(String.self, forKey: .baseModel)
        // Some uploaders supply this field in a non-array shape. Preserve all
        // the established generation fields even when it cannot be decoded.
        civitaiResources = try? values.decode([CivitaiResourceReference].self, forKey: .civitaiResources)
    }

    init(
        prompt: String?, negativePrompt: String?, cfgScale: Double?, steps: Int?,
        sampler: String?, seed: Int?, clipSkip: Int?, baseModel: String? = nil,
        civitaiResources: [CivitaiResourceReference]? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.cfgScale = cfgScale
        self.steps = steps
        self.sampler = sampler
        self.seed = seed
        self.clipSkip = clipSkip
        self.baseModel = baseModel
        self.civitaiResources = civitaiResources
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
