import Testing
import Foundation
@testable import Diffusely

@Suite struct A1111ParametersParserTests {
    // A realistic captured sample (prompt with inline LoRAs, negative, param tail).
    let sample = """
    masterpiece, best quality, <lora:detailEnhancer:0.8>, a young woman, <lora:styleX:0.5>
    Negative prompt: worst quality, bad anatomy
    Steps: 30, Sampler: Euler a Karras, CFG scale: 4.0, Seed: 818544170345672, Size: 1248x1824, Clip skip: 2, Model hash: 38FB5B8E02, Model: Nickel Saffron Manga, Version: ComfyUI
    """

    @Test func parsesPromptNegativeAndFields() {
        let result = A1111ParametersParser.parse(sample)
        #expect(result != nil)
        #expect(result?.prompt == "masterpiece, best quality, <lora:detailEnhancer:0.8>, a young woman, <lora:styleX:0.5>")
        #expect(result?.negativePrompt == "worst quality, bad anatomy")
    }

    @Test func preservesFieldOrderAndValues() {
        let fields = A1111ParametersParser.parse(sample)?.fields ?? []
        let keys = fields.map(\.key)
        #expect(keys == ["Steps", "Sampler", "CFG scale", "Seed", "Size", "Clip skip", "Model hash", "Model", "Version"])
        #expect(fields.first(where: { $0.key == "Sampler" })?.value == "Euler a Karras")
        #expect(fields.first(where: { $0.key == "Model" })?.value == "Nickel Saffron Manga")
    }

    @Test func preservesInlineLoraOrderingInPrompt() {
        let prompt = A1111ParametersParser.parse(sample)?.prompt ?? ""
        let first = prompt.range(of: "<lora:detailEnhancer:0.8>")
        let second = prompt.range(of: "<lora:styleX:0.5>")
        #expect(first != nil && second != nil)
        #expect(first!.lowerBound < second!.lowerBound)
    }

    @Test func handlesQuotedValueContainingCommas() {
        let s = "a prompt\nSteps: 20, Lora hashes: \"add_detail: abc123, styleX: def456\", Seed: 7"
        let fields = A1111ParametersParser.parse(s)?.fields ?? []
        #expect(fields.first(where: { $0.key == "Lora hashes" })?.value == "add_detail: abc123, styleX: def456")
        #expect(fields.first(where: { $0.key == "Seed" })?.value == "7")
    }

    @Test func returnsNilForNonA1111Strings() {
        #expect(A1111ParametersParser.parse("just a bare prompt with no parameter tail") == nil)
        #expect(A1111ParametersParser.parse("{\"5\": {\"inputs\": {}}}") == nil)
    }

    @Test func parsesPromptWithoutNegative() {
        let s = "only positive prompt\nSteps: 10, Sampler: DDIM"
        let result = A1111ParametersParser.parse(s)
        #expect(result?.prompt == "only positive prompt")
        #expect(result?.negativePrompt == nil)
        #expect(result?.fields.map(\.key) == ["Steps", "Sampler"])
    }

    @Test func emptyNegativePromptIsNil() {
        let s = "a prompt\nNegative prompt: \nSteps: 20, Sampler: DDIM"
        let result = A1111ParametersParser.parse(s)
        #expect(result?.prompt == "a prompt")
        #expect(result?.negativePrompt == nil)
    }

    @Test func returnsNilForEmptyOrWhitespaceInput() {
        #expect(A1111ParametersParser.parse("") == nil)
        #expect(A1111ParametersParser.parse("   \n  \t ") == nil)
    }

    @Test func handlesCRLFLineEndings() {
        let s = "a prompt\r\nNegative prompt: bad\r\nSteps: 20, Sampler: DDIM"
        let result = A1111ParametersParser.parse(s)
        #expect(result?.prompt == "a prompt")
        #expect(result?.negativePrompt == "bad")
        #expect(result?.fields.map(\.key) == ["Steps", "Sampler"])
    }
}
