import Testing
import Foundation
@testable import Diffusely

@Suite struct ComfyFixtureTests {
    @Test(arguments: ComfyFixtures.all.map(\.name))
    func realWorkflowParsesAndSummarizes(name: String) throws {
        let json = try #require(ComfyFixtures.all.first { $0.name == name }?.json)
        let graph = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        let recipe = ComfyRecipeBuilder.build(graph)

        #expect(!recipe.passes.isEmpty, "\(name): no sampling pass found")
        #expect(recipe.unattributed.count < graph.nodes.count, "\(name): nothing was attributed")
        for pass in recipe.passes {
            #expect(!pass.modelChain.isEmpty, "\(name): pass #\(pass.anchor) has no model chain")
            #expect(pass.sampler.seed != nil || pass.sampler.steps != nil,
                    "\(name): pass #\(pass.anchor) read no sampler settings")
            #expect(!pass.positive.isEmpty || !pass.unrecognized.isEmpty,
                    "\(name): pass #\(pass.anchor) found no prompt and no unrecognized node to explain it")
            #expect(pass.nodeIDs.contains(pass.anchor))
        }
        #expect(!recipe.resources.baseModels.isEmpty || recipe.passes.contains { !$0.unrecognized.isEmpty },
                "\(name): no base model and nothing unrecognized")
    }

    @Test func nodeHeavyIsOnePassThroughCustomNodes() throws {
        let graph = try ComfyGraphParser.parse(prompt: ComfyFixtures.nodeHeavy, workflow: nil)
        let recipe = ComfyRecipeBuilder.build(graph)
        #expect(graph.nodes.count == 21)
        #expect(recipe.passes.count == 1)
        let pass = try #require(recipe.passes.first)
        #expect(pass.anchor == "7")
        #expect(pass.sampler.seed == 1820)
        #expect(pass.sampler.steps == 11)
        #expect(pass.sampler.samplerName == "lcm")
        #expect(pass.sampler.scheduler == "beta")
        // Model chain passes through the rgthree Power Lora Loader (unknown) and the Kohya deep-shrink patch (known modifier) to the checkpoint.
        #expect(pass.modelChain.first == .base(name: "mopInsta\\mopInsta_v10_00001_.safetensors", classType: "CheckpointLoaderSimple"))
        #expect(pass.unrecognized.contains("162"))
        #expect(pass.modifiers.contains("PatchModelAddDownscale"))
        #expect(pass.positive.first?.text.hasPrefix("(candid analog amateur jpg:1.2)") == true)
        // The latent comes from a custom size-picker node with no latent input to follow.
        #expect(pass.latentSource == .unknown)
        #expect(pass.unrecognized.contains("18"))
        // Both FaceDetailers sit between the sampler and SaveImage, so they are output plumbing on this pass.
        #expect(pass.nodeIDs.isSuperset(of: ["128", "189", "183:186", "182:179", "13", "7"]))
        #expect(recipe.resources.baseModels == ["mopInsta\\mopInsta_v10_00001_.safetensors"])
    }
}
