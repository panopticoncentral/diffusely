import Testing
import Foundation
@testable import Diffusely

@Suite struct ComfyRecipeBuilderTests {
    // MARK: - DSL

    static func node(_ id: String, _ cls: String, _ inputs: [String: ComfyInput] = [:]) -> ComfyNode {
        ComfyNode(id: id, classType: cls, title: nil,
                  inputs: inputs.keys.sorted().map { ComfyNodeInput(key: $0, value: inputs[$0]!) })
    }
    /// Last definition of an id wins, so a test can override a node from `txt2img` via `extra:`.
    static func graph(_ nodes: [ComfyNode]) -> ComfyGraph {
        ComfyGraph.make(nodes: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }))
    }
    static func link(_ id: String, _ slot: Int = 0) -> ComfyInput { .link(node: id, slot: slot) }
    static func str(_ s: String) -> ComfyInput { .value(.string(s)) }
    static func int(_ i: Int64) -> ComfyInput { .value(.integer(i)) }
    static func num(_ d: Double) -> ComfyInput { .value(.number(d)) }

    /// Checkpoint(4) → CLIPTextEncode(6,7) → KSampler(3) ← EmptyLatent(5); VAEDecode(8) → SaveImage(9).
    /// `samplerModel` lets a test splice LoRAs between the checkpoint and the sampler.
    static func txt2img(samplerModel: String = "4", extra: [ComfyNode] = []) -> ComfyGraph {
        graph([
            node("4", "CheckpointLoaderSimple", ["ckpt_name": str("sdxl_base.safetensors")]),
            node("5", "EmptyLatentImage", ["width": int(1024), "height": int(1024), "batch_size": int(1)]),
            node("6", "CLIPTextEncode", ["text": str("a cat"), "clip": link("4", 1)]),
            node("7", "CLIPTextEncode", ["text": str("blurry"), "clip": link("4", 1)]),
            node("3", "KSampler", ["model": link(samplerModel), "positive": link("6"), "negative": link("7"),
                                   "latent_image": link("5"), "seed": int(42), "steps": int(20), "cfg": num(7),
                                   "sampler_name": str("euler"), "scheduler": str("normal"), "denoise": num(1)]),
            node("8", "VAEDecode", ["samples": link("3"), "vae": link("4", 2)]),
            node("9", "SaveImage", ["images": link("8"), "filename_prefix": str("out")]),
        ] + extra)
    }

    // MARK: - Task 4

    @Test func singlePassTxt2img() {
        let recipe = ComfyRecipeBuilder.build(Self.txt2img())
        #expect(recipe.passes.count == 1)
        let pass = recipe.passes[0]
        #expect(pass.anchor == "3")
        #expect(pass.anchorClass == "KSampler")
        #expect(pass.sampler == SamplerSettings(seed: 42, steps: 20, cfg: 7, samplerName: "euler",
                                                scheduler: "normal", denoise: 1))
        #expect(pass.modelChain == [.base(name: "sdxl_base.safetensors", classType: "CheckpointLoaderSimple")])
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.negative == [ConditioningText(text: "blurry", nodeID: "7")])
        #expect(pass.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(pass.modifiers.isEmpty)
        #expect(pass.unrecognized.isEmpty)
        #expect(recipe.resources.baseModels == ["sdxl_base.safetensors"])
        #expect(recipe.unattributed.isEmpty)
    }

    @Test func loraChainInApplyOrderWithStrengths() {
        let g = Self.txt2img(samplerModel: "11", extra: [
            Self.node("10", "LoraLoader", ["model": Self.link("4"), "clip": Self.link("4", 1),
                                           "lora_name": Self.str("detail.safetensors"),
                                           "strength_model": Self.num(0.8), "strength_clip": Self.num(0.8)]),
            Self.node("11", "LoraLoaderModelOnly", ["model": Self.link("10"),
                                                    "lora_name": Self.str("style.safetensors"),
                                                    "strength_model": Self.num(0.6)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [
            .base(name: "sdxl_base.safetensors", classType: "CheckpointLoaderSimple"),
            .lora(name: "detail.safetensors", strengthModel: 0.8, strengthClip: 0.8),
            .lora(name: "style.safetensors", strengthModel: 0.6, strengthClip: nil),
        ])
        #expect(ComfyRecipeBuilder.build(g).resources.loras == [
            LoraResource(name: "detail.safetensors", strength: 0.8),
            LoraResource(name: "style.safetensors", strength: 0.6),
        ])
        #expect(pass.nodeIDs.isSuperset(of: ["10", "11"]))
    }

    @Test func outputPlumbingAndVAEAttributedToPass() {
        let g = Self.txt2img(extra: [
            Self.node("12", "VAELoader", ["vae_name": Self.str("ae.safetensors")]),
            // Rewire VAEDecode's vae to the standalone loader.
            Self.node("8", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("12")]),
            Self.node("99", "Note", ["text": Self.str("disconnected")]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        let pass = recipe.passes[0]
        #expect(pass.nodeIDs.isSuperset(of: ["9", "8", "12", "3", "4", "5", "6", "7"]))
        #expect(recipe.resources.vaes == ["ae.safetensors"])
        #expect(recipe.unattributed == ["99"])
    }

    @Test func widgetLinksResolveThroughPrimitives() {
        let g = Self.graph([
            Self.node("4", "CheckpointLoaderSimple", ["ckpt_name": Self.str("m.safetensors")]),
            Self.node("5", "EmptyLatentImage", ["width": Self.int(512), "height": Self.int(512), "batch_size": Self.int(1)]),
            Self.node("20", "Seed Generator", ["seed": Self.int(7)]),
            Self.node("21", "String Literal", ["string": Self.str("from primitive")]),
            Self.node("6", "CLIPTextEncode", ["text": Self.link("21"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncode", ["text": Self.str("neg"), "clip": Self.link("4", 1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.link("20"), "steps": Self.int(10),
                                        "cfg": Self.num(5), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"),
                                        "denoise": Self.num(1)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("4", 2)]),
            Self.node("9", "SaveImage", ["images": Self.link("8")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.sampler.seed == 7)
        #expect(pass.positive == [ConditioningText(text: "from primitive", nodeID: "6")])
        #expect(pass.nodeIDs.isSuperset(of: ["20", "21"]))
    }

    @Test func widgetLinkDepthIsCapped() {
        // seed → p1 → p2 → … → p7 → literal. Seven hops exceed the cap of five.
        var nodes: [ComfyNode] = [
            Self.node("4", "CheckpointLoaderSimple", ["ckpt_name": Self.str("m")]),
            Self.node("5", "EmptyLatentImage", ["width": Self.int(8), "height": Self.int(8), "batch_size": Self.int(1)]),
            Self.node("6", "CLIPTextEncode", ["text": Self.str("p"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncode", ["text": Self.str("n"), "clip": Self.link("4", 1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.link("p1"), "steps": Self.int(1),
                                        "cfg": Self.num(1), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"),
                                        "denoise": Self.num(1)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("4", 2)]),
            Self.node("9", "SaveImage", ["images": Self.link("8")]),
        ]
        for i in 1...6 { nodes.append(Self.node("p\(i)", "Relay", ["value": Self.link("p\(i + 1)")])) }
        nodes.append(Self.node("p7", "Relay", ["value": Self.int(5)]))
        let pass = ComfyRecipeBuilder.build(Self.graph(nodes)).passes[0]
        #expect(pass.sampler.seed == nil)
    }

    // MARK: - Task 5

    /// Pass "3" (from txt2img) → LatentUpscaleBy(13) → KSampler "2" (deliberately lower id) → VAEDecode(8) → SaveImage(9).
    static func hiresFix() -> ComfyGraph {
        Self.txt2img(extra: [
            Self.node("13", "LatentUpscaleBy", ["samples": Self.link("3"), "upscale_method": Self.str("nearest-exact"), "scale_by": Self.num(1.5)]),
            Self.node("2", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("13"), "seed": Self.int(42), "steps": Self.int(12), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(0.5)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("2"), "vae": Self.link("4", 2)]),
        ])
    }

    @Test func hiresFixIsTwoOrderedPasses() {
        let recipe = ComfyRecipeBuilder.build(Self.hiresFix())
        #expect(recipe.passes.map(\.anchor) == ["3", "2"]) // topological, not numeric
        let first = recipe.passes[0], second = recipe.passes[1]
        #expect(first.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(second.latentSource == .fromPass("3", via: ["LatentUpscaleBy"]))
        #expect(second.sampler.denoise == 0.5)
        #expect(second.nodeIDs.contains("13"))
        #expect(!first.nodeIDs.contains("13"))
        #expect(second.nodeIDs.isSuperset(of: ["8", "9"]))
        #expect(!first.nodeIDs.contains("9"))
        #expect(first.nodeIDs.contains("4") && second.nodeIDs.contains("4")) // shared loader in both
        #expect(recipe.unattributed.isEmpty)
    }

    @Test func img2imgLatentComesFromLoadedImage() {
        let g = Self.txt2img(extra: [
            Self.node("15", "LoadImage", ["image": Self.str("input.png"), "upload": Self.str("image")]),
            Self.node("16", "VAEEncode", ["pixels": Self.link("15"), "vae": Self.link("4", 2)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("16"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(0.7)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.latentSource == .image(loadNode: "15", name: "input.png", via: []))
        #expect(pass.nodeIDs.isSuperset(of: ["15", "16"]))
    }

    @Test func pixelSpaceUpscaleBetweenPassesRecordsViaAndModel() {
        let g = Self.txt2img(extra: [
            Self.node("17", "VAEDecode", ["samples": Self.link("3"), "vae": Self.link("4", 2)]),
            Self.node("19", "UpscaleModelLoader", ["model_name": Self.str("4x_foolhardy.pth")]),
            Self.node("18", "ImageUpscaleWithModel", ["upscale_model": Self.link("19"), "image": Self.link("17")]),
            Self.node("20", "VAEEncode", ["pixels": Self.link("18"), "vae": Self.link("4", 2)]),
            Self.node("14", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                         "latent_image": Self.link("20"), "seed": Self.int(1), "steps": Self.int(10), "cfg": Self.num(7),
                                         "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(0.4)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("14"), "vae": Self.link("4", 2)]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        #expect(recipe.passes.map(\.anchor) == ["3", "14"])
        #expect(recipe.passes[1].latentSource == .fromPass("3", via: ["ImageUpscaleWithModel"]))
        #expect(recipe.resources.upscaleModels == ["4x_foolhardy.pth"])
        #expect(recipe.passes[1].nodeIDs.isSuperset(of: ["17", "18", "19", "20"]))
    }

    // MARK: - Task 6

    @Test func conditioningCombineYieldsBothTexts() {
        let g = Self.txt2img(extra: [
            Self.node("61", "CLIPTextEncode", ["text": Self.str("oil painting"), "clip": Self.link("4", 1)]),
            Self.node("60", "ConditioningCombine", ["conditioning_1": Self.link("6"), "conditioning_2": Self.link("61")]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("60"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6"),
                                  ConditioningText(text: "oil painting", nodeID: "61")])
    }

    @Test func controlNetIsRecordedAndTextStillReached() {
        let g = Self.txt2img(extra: [
            Self.node("50", "ControlNetLoader", ["control_net_name": Self.str("canny.safetensors")]),
            Self.node("51", "LoadImage", ["image": Self.str("edges.png")]),
            Self.node("52", "ControlNetApplyAdvanced", ["positive": Self.link("6"), "negative": Self.link("7"),
                                                        "control_net": Self.link("50"), "image": Self.link("51"),
                                                        "strength": Self.num(0.8), "start_percent": Self.num(0), "end_percent": Self.num(1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("52", 0), "negative": Self.link("52", 1),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        let pass = recipe.passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.negative == [ConditioningText(text: "blurry", nodeID: "7")])
        #expect(pass.modifiers.contains("ControlNetApplyAdvanced"))
        #expect(recipe.resources.controlNets == ["canny.safetensors"])
        #expect(pass.nodeIDs.isSuperset(of: ["50", "52"]))
    }

    @Test func sdxlEncoderJoinsDistinctTexts() {
        let g = Self.txt2img(extra: [
            Self.node("6", "CLIPTextEncodeSDXL", ["text_g": Self.str("a cat"), "text_l": Self.str("a cat"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncodeSDXL", ["text_g": Self.str("blurry"), "text_l": Self.str("jpeg artifacts"), "clip": Self.link("4", 1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.negative == [ConditioningText(text: "blurry\njpeg artifacts", nodeID: "7")])
    }

    @Test func kSamplerAdvancedReadsStepRange() {
        let g = Self.txt2img(extra: [
            Self.node("3", "KSamplerAdvanced", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                                "latent_image": Self.link("5"), "add_noise": Self.str("enable"), "noise_seed": Self.int(5),
                                                "steps": Self.int(30), "cfg": Self.num(6), "sampler_name": Self.str("dpmpp_2m"),
                                                "scheduler": Self.str("karras"), "start_at_step": Self.int(0), "end_at_step": Self.int(20),
                                                "return_with_leftover_noise": Self.str("disable")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.sampler == SamplerSettings(seed: 5, steps: 30, cfg: 6, samplerName: "dpmpp_2m",
                                                scheduler: "karras", denoise: nil, startStep: 0, endStep: 20))
    }

    /// `SamplerCustom` (not the Advanced variant): seed and cfg on the node,
    /// name from the select node and steps/scheduler/denoise from the sigmas node.
    @Test func samplerCustomReadsSelectAndSigmas() {
        let g = Self.txt2img(extra: [
            Self.node("36", "KSamplerSelect", ["sampler_name": Self.str("euler")]),
            Self.node("37", "BasicScheduler", ["model": Self.link("4"), "steps": Self.int(15),
                                               "scheduler": Self.str("karras"), "denoise": Self.num(1)]),
            Self.node("3", "SamplerCustom", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                             "latent_image": Self.link("5"), "noise_seed": Self.int(77), "cfg": Self.num(4),
                                             "sampler": Self.link("36"), "sigmas": Self.link("37")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.anchorClass == "SamplerCustom")
        #expect(pass.sampler == SamplerSettings(seed: 77, steps: 15, cfg: 4, samplerName: "euler",
                                                scheduler: "karras", denoise: 1))
    }

    @Test func fluxSamplerCustomAdvancedCluster() {
        let g = Self.graph([
            Self.node("30", "UNETLoader", ["unet_name": Self.str("flux1-dev.safetensors"), "weight_dtype": Self.str("default")]),
            Self.node("31", "DualCLIPLoader", ["clip_name1": Self.str("t5xxl.safetensors"), "clip_name2": Self.str("clip_l.safetensors"), "type": Self.str("flux")]),
            Self.node("32", "CLIPTextEncode", ["text": Self.str("a fox"), "clip": Self.link("31")]),
            Self.node("33", "FluxGuidance", ["conditioning": Self.link("32"), "guidance": Self.num(3.5)]),
            Self.node("34", "BasicGuider", ["model": Self.link("30"), "conditioning": Self.link("33")]),
            Self.node("35", "RandomNoise", ["noise_seed": Self.int(123)]),
            Self.node("36", "KSamplerSelect", ["sampler_name": Self.str("euler")]),
            Self.node("37", "BasicScheduler", ["model": Self.link("30"), "scheduler": Self.str("simple"), "steps": Self.int(20), "denoise": Self.num(1)]),
            Self.node("38", "EmptySD3LatentImage", ["width": Self.int(1024), "height": Self.int(1024), "batch_size": Self.int(1)]),
            Self.node("39", "SamplerCustomAdvanced", ["noise": Self.link("35"), "guider": Self.link("34"), "sampler": Self.link("36"),
                                                      "sigmas": Self.link("37"), "latent_image": Self.link("38")]),
            Self.node("40", "VAELoader", ["vae_name": Self.str("ae.safetensors")]),
            Self.node("41", "VAEDecode", ["samples": Self.link("39", 0), "vae": Self.link("40")]),
            Self.node("42", "SaveImage", ["images": Self.link("41")]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        #expect(recipe.passes.count == 1)
        let pass = recipe.passes[0]
        #expect(pass.anchor == "39")
        #expect(pass.sampler == SamplerSettings(seed: 123, steps: 20, cfg: 3.5, samplerName: "euler",
                                                scheduler: "simple", denoise: 1))
        #expect(pass.modelChain == [.base(name: "flux1-dev.safetensors", classType: "UNETLoader")])
        #expect(pass.positive == [ConditioningText(text: "a fox", nodeID: "32")])
        #expect(pass.negative.isEmpty)
        #expect(pass.modifiers.contains("FluxGuidance"))
        #expect(pass.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(recipe.resources.vaes == ["ae.safetensors"])
        #expect(pass.nodeIDs.isSuperset(of: ["34", "35", "36", "37", "33", "32"]))
        #expect(recipe.unattributed == ["31"]) // the CLIP loader is not on any role walk
    }

    // MARK: - Task 7

    @Test func unknownModelNodeIsPassedThroughAndReported() {
        let g = Self.txt2img(samplerModel: "70", extra: [
            Self.node("70", "SomeCustomPatch", ["model": Self.link("4"), "strength": Self.num(0.3)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [.base(name: "sdxl_base.safetensors", classType: "CheckpointLoaderSimple")])
        #expect(pass.unrecognized == ["70"])
        #expect(pass.nodeIDs.contains("70"))
    }

    @Test func unknownTerminalNodeEndsChainWithUnknownBase() {
        let g = Self.txt2img(samplerModel: "71", extra: [
            Self.node("71", "MysteryLoader", ["path": Self.str("/models/x")]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [.base(name: nil, classType: "MysteryLoader")])
        #expect(pass.unrecognized == ["71"])
    }

    @Test func unknownConditioningNodeIsPassedThrough() {
        let g = Self.txt2img(extra: [
            Self.node("72", "CustomPromptBooster", ["conditioning": Self.link("6"), "boost": Self.num(2)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("72"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
        #expect(pass.unrecognized == ["72"])
    }

    @Test func unknownLatentNodeIsPassedThrough() {
        let g = Self.txt2img(extra: [
            Self.node("73", "LatentNoiseInjector", ["samples": Self.link("5"), "amount": Self.num(0.1)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("73"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.latentSource == .empty(width: 1024, height: 1024, batch: 1))
        #expect(pass.unrecognized == ["73"])
    }

    @Test func unknownLatentNodeWithNoMatchingInputIsUnknownSource() {
        let g = Self.txt2img(extra: [
            Self.node("74", "LatentFromNowhere", ["seed": Self.int(9)]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"),
                                        "latent_image": Self.link("74"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.latentSource == .unknown)
        #expect(pass.unrecognized == ["74"])
    }

    @Test func modelCycleTerminates() {
        let g = Self.txt2img(samplerModel: "80", extra: [
            Self.node("80", "LoraLoader", ["model": Self.link("81"), "lora_name": Self.str("a"), "strength_model": Self.num(1), "strength_clip": Self.num(1)]),
            Self.node("81", "LoraLoader", ["model": Self.link("80"), "lora_name": Self.str("b"), "strength_model": Self.num(1), "strength_clip": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain.count == 3)
        #expect(pass.modelChain[0] == .base(name: nil, classType: "unknown"))
    }

    @Test func mutualLatentCycleTerminates() {
        // Two samplers feeding each other's latent — impossible in ComfyUI, but
        // the builder must not recurse forever.
        let g = Self.graph([
            Self.node("4", "CheckpointLoaderSimple", ["ckpt_name": Self.str("m")]),
            Self.node("6", "CLIPTextEncode", ["text": Self.str("p"), "clip": Self.link("4", 1)]),
            Self.node("7", "CLIPTextEncode", ["text": Self.str("n"), "clip": Self.link("4", 1)]),
            Self.node("1", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"), "latent_image": Self.link("2"),
                                        "seed": Self.int(1), "steps": Self.int(1), "cfg": Self.num(1), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
            Self.node("2", "KSampler", ["model": Self.link("4"), "positive": Self.link("6"), "negative": Self.link("7"), "latent_image": Self.link("1"),
                                        "seed": Self.int(2), "steps": Self.int(1), "cfg": Self.num(1), "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
            Self.node("8", "VAEDecode", ["samples": Self.link("2"), "vae": Self.link("4", 2)]),
            Self.node("9", "SaveImage", ["images": Self.link("8")]),
        ])
        let recipe = ComfyRecipeBuilder.build(g)
        #expect(recipe.passes.count == 2)
    }

    /// A combiner wired back into itself. Without a visited set the combiner
    /// branch fans out over every link input, so this is exponential in depth.
    @Test func conditioningCombinerCycleTerminates() {
        let g = Self.txt2img(extra: [
            Self.node("90", "ConditioningCombine", ["conditioning_1": Self.link("6"), "conditioning_2": Self.link("90")]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("90"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
    }

    /// Two unrecognized nodes passing conditioning to each other.
    @Test func unknownConditioningCycleTerminates() {
        let g = Self.txt2img(extra: [
            Self.node("91", "CustomA", ["conditioning": Self.link("92")]),
            Self.node("92", "CustomB", ["conditioning": Self.link("91")]),
            Self.node("3", "KSampler", ["model": Self.link("4"), "positive": Self.link("91"), "negative": Self.link("7"),
                                        "latent_image": Self.link("5"), "seed": Self.int(1), "steps": Self.int(20), "cfg": Self.num(7),
                                        "sampler_name": Self.str("euler"), "scheduler": Self.str("normal"), "denoise": Self.num(1)]),
        ])
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.positive.isEmpty)
        #expect(pass.unrecognized.contains("91"))
        #expect(pass.unrecognized.contains("92"))
    }

    @Test func danglingLinksResolveToNothing() {
        let g = Self.txt2img(samplerModel: "404")
        let pass = ComfyRecipeBuilder.build(g).passes[0]
        #expect(pass.modelChain == [.base(name: nil, classType: "unknown")])
        #expect(pass.positive == [ConditioningText(text: "a cat", nodeID: "6")])
    }
}
