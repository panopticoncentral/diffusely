import Testing
import Foundation
@testable import Diffusely

@Suite struct ComfyGraphParserTests {
    private func input(_ node: ComfyNode, _ key: String) -> ComfyInput? {
        node.inputs.first(where: { $0.key == key })?.value
    }

    @Test func linksVersusLiteralArrays() throws {
        let json = #"{"1":{"class_type":"A","inputs":{"x":["2",0],"y":[1,2],"z":["a","b"],"s":"hi","b":true}},"2":{"class_type":"B","inputs":{}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        let a = try #require(g.nodes["1"])
        #expect(input(a, "x") == .link(node: "2", slot: 0))
        #expect(input(a, "y") == .value(.array([.integer(1), .integer(2)])))
        #expect(input(a, "z") == .value(.array([.string("a"), .string("b")])))
        #expect(input(a, "s") == .value(.string("hi")))
        #expect(input(a, "b") == .value(.bool(true)))
        #expect(a.inputs.map(\.key) == ["b", "s", "x", "y", "z"]) // sorted for stable display
    }

    @Test func outputsAreUnconsumedNodes() throws {
        let json = #"{"1":{"class_type":"Save","inputs":{"images":["2",0]}},"2":{"class_type":"Decode","inputs":{}},"3":{"class_type":"Loose","inputs":{}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        #expect(g.outputs == ["1", "3"])
    }

    @Test func danglingLinkRecordedNotThrown() throws {
        let json = #"{"1":{"class_type":"A","inputs":{"x":["99",0]}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        #expect(g.danglingLinks == [DanglingLink(from: "1", input: "x")])
        #expect(input(g.nodes["1"]!, "x") == .link(node: "99", slot: 0))
    }

    @Test func nanIsSanitizedOnlyWhenCleanDecodeFails() throws {
        let bad = #"{"1":{"class_type":"A","inputs":{"v":NaN,"arr":[NaN]}}}"#
        let g = try ComfyGraphParser.parse(prompt: bad, workflow: nil)
        #expect(input(g.nodes["1"]!, "v") == .value(.integer(0)))
        #expect(input(g.nodes["1"]!, "arr") == .value(.array([])))

        // Scalar Infinity — signed and unsigned — is as illegal as NaN.
        let inf = #"{"1":{"class_type":"A","inputs":{"v":Infinity,"w":-Infinity,"arr":[Infinity]}}}"#
        let g3 = try ComfyGraphParser.parse(prompt: inf, workflow: nil)
        #expect(input(g3.nodes["1"]!, "v") == .value(.integer(0)))
        #expect(input(g3.nodes["1"]!, "w") == .value(.integer(0)))
        #expect(input(g3.nodes["1"]!, "arr") == .value(.array([])))

        // Valid JSON containing the word NaN inside a string is left alone.
        let fine = #"{"1":{"class_type":"A","inputs":{"text":"NaN and Infinity"}}}"#
        let g2 = try ComfyGraphParser.parse(prompt: fine, workflow: nil)
        #expect(input(g2.nodes["1"]!, "text") == .value(.string("NaN and Infinity")))
    }

    @Test func bigSeedsKeepPrecision() throws {
        let json = #"{"1":{"class_type":"A","inputs":{"seed":18446744073709551615,"neg":-3,"small":42}}}"#
        let g = try ComfyGraphParser.parse(prompt: json, workflow: nil)
        #expect(input(g.nodes["1"]!, "seed") == .value(.unsigned(18446744073709551615)))
        #expect(input(g.nodes["1"]!, "neg") == .value(.integer(-3)))
        #expect(input(g.nodes["1"]!, "small") == .value(.integer(42)))
        #expect(ComfyValue.unsigned(18446744073709551615).displayText == "18446744073709551615")
    }

    @Test func workflowTitlesEnrichNodes() throws {
        let prompt = #"{"1":{"class_type":"A","inputs":{}},"2":{"class_type":"B","inputs":{},"_meta":{"title":"From prompt"}}}"#
        let workflow = #"{"nodes":[{"id":1,"type":"A","title":"Fancy A"},{"id":2,"type":"B","title":"Ignored"}]}"#
        let g = try ComfyGraphParser.parse(prompt: prompt, workflow: workflow)
        #expect(g.nodes["1"]?.title == "Fancy A")
        #expect(g.nodes["2"]?.title == "From prompt") // _meta.title wins
    }

    @Test func unparseableWorkflowDoesNotFailGraph() throws {
        let prompt = #"{"1":{"class_type":"A","inputs":{}}}"#
        let g = try ComfyGraphParser.parse(prompt: prompt, workflow: "{{not json")
        #expect(g.nodes.count == 1)
        #expect(g.nodes["1"]?.title == nil)
    }

    @Test func notAGraphWhenNoClassType() {
        #expect(throws: ComfyParseError.notAGraph) {
            try ComfyGraphParser.parse(prompt: #"{"a":1,"b":{"x":2}}"#, workflow: nil)
        }
        #expect(throws: ComfyParseError.notAGraph) {
            try ComfyGraphParser.parse(prompt: #"[1,2,3]"#, workflow: nil)
        }
    }

    @Test func malformedJSONThrows() {
        #expect(throws: ComfyParseError.malformedJSON) {
            try ComfyGraphParser.parse(prompt: "not json at all", workflow: nil)
        }
    }

    @Test func numericIDSortOrdersNumbersThenStrings() {
        let ids = ["10", "2", "b", "a", "1"]
        #expect(ids.sorted(by: ComfyGraph.numericIDSort) == ["1", "2", "10", "a", "b"])
    }
}
