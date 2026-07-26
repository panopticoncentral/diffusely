import Testing
import Foundation
@testable import Diffusely

/// Unit tests for the devalue reader (`DevalueDecoder.parse`) and the tRPC
/// envelope normalizer (`TRPCEnvelope.normalize`). All devalue fixtures are the
/// exact output of `devalue.stringify` (v5.8.1 — the version Civitai ships).
@Suite struct DevalueDecoderTests {

    // MARK: Primitives

    @Test func parsesTopLevelNumber() throws {
        #expect((try DevalueDecoder.parse("[42]") as? NSNumber)?.intValue == 42)
    }

    @Test func parsesTopLevelString() throws {
        #expect(try DevalueDecoder.parse(#"["hello"]"#) as? String == "hello")
    }

    @Test func parsesTopLevelBool() throws {
        #expect((try DevalueDecoder.parse("[true]") as? NSNumber)?.boolValue == true)
    }

    // MARK: Objects, arrays, null

    @Test func parsesNulls() throws {
        let d = try #require(try DevalueDecoder.parse(#"[{"a":1,"b":2,"c":3},null,1,"x"]"#) as? [String: Any])
        #expect(d["a"] is NSNull)
        #expect((d["b"] as? NSNumber)?.intValue == 1)
        #expect(d["c"] as? String == "x")
    }

    @Test func parsesNestedObjectsAndArrays() throws {
        let d = try #require(try DevalueDecoder.parse(
            #"[{"ok":1,"list":2,"meta":6},true,[3,4,5],1,2,3,{"x":7,"n":8},"y",0]"#) as? [String: Any])
        #expect((d["ok"] as? NSNumber)?.boolValue == true)
        let list = try #require(d["list"] as? [Any])
        #expect(list.compactMap { ($0 as? NSNumber)?.intValue } == [1, 2, 3])
        let meta = try #require(d["meta"] as? [String: Any])
        #expect(meta["x"] as? String == "y")
        #expect((meta["n"] as? NSNumber)?.intValue == 0)
    }

    @Test func parsesNestedArrays() throws {
        // [[1,2],[3,[4,5]]]
        let a = try #require(try DevalueDecoder.parse("[[1,4],[2,3],1,2,[5,6],3,[7,8],4,5]") as? [Any])
        let first = try #require(a[0] as? [Any])
        #expect(first.compactMap { ($0 as? NSNumber)?.intValue } == [1, 2])
        let second = try #require(a[1] as? [Any])
        #expect((second[0] as? NSNumber)?.intValue == 3)
        let inner = try #require(second[1] as? [Any])
        #expect(inner.compactMap { ($0 as? NSNumber)?.intValue } == [4, 5])
    }

    @Test func parsesEmptyObject() throws {
        #expect(try #require(try DevalueDecoder.parse("[{}]") as? [String: Any]).isEmpty)
    }

    @Test func parsesSparseArray() throws {
        // devalue's SPARSE (-7) encoding for [ "x", <4 holes>, "y" ] (length 6).
        let a = try #require(try DevalueDecoder.parse(#"[[-7,6,0,1,5,2],"x","y"]"#) as? [Any])
        #expect(a.count == 6)
        #expect(a[0] as? String == "x")
        #expect(a[1] is NSNull)
        #expect(a[4] is NSNull)
        #expect(a[5] as? String == "y")
    }

    // MARK: The reference / dedup mechanic

    @Test func resolvesSharedReferenceToSameInstance() throws {
        // {a: o, b: o} where both point to the same {k:"v"} — devalue stores it
        // once and references it twice; the reader must resolve both to ONE object.
        let d = try #require(try DevalueDecoder.parse(#"[{"a":1,"b":1},{"k":2},"v"]"#) as? NSDictionary)
        let a = d["a"] as AnyObject
        let b = d["b"] as AnyObject
        #expect(a === b)
        #expect((a as? NSDictionary)?["k"] as? String == "v")
    }

    // MARK: undefined & holes

    @Test func omitsUndefinedObjectKeys() throws {
        // {a: undefined, b: 2} — `a` maps to index -1 (UNDEFINED) → key dropped
        // (JSON has no `undefined`, matching JSON.stringify's behavior).
        let d = try #require(try DevalueDecoder.parse(#"[{"a":-1,"b":1},2]"#) as? [String: Any])
        #expect(d.keys.contains("a") == false)
        #expect((d["b"] as? NSNumber)?.intValue == 2)
    }

    @Test func arrayHolesBecomeNull() throws {
        // [1, <hole>, 3] — HOLE (-2) → null (JSON arrays are dense).
        let a = try #require(try DevalueDecoder.parse("[[1,-2,2],1,3]") as? [Any])
        #expect((a[0] as? NSNumber)?.intValue == 1)
        #expect(a[1] is NSNull)
        #expect((a[2] as? NSNumber)?.intValue == 3)
    }

    // MARK: Realistic feed payload (deduped fields shared across two items)

    @Test func parsesFeedPayload() throws {
        let feed = #"[{"nextCursor":1,"items":2,"source":20},"20|123",[3,14],{"id":4,"url":5,"width":6,"height":7,"nsfwLevel":4,"type":8,"postId":9,"user":10,"stats":13},1,"uuid-1",10,20,"image",100,{"id":11,"username":12,"image":13},5,"alice",null,{"id":15,"url":16,"width":17,"height":18,"nsfwLevel":19,"type":8,"postId":9,"user":10,"stats":13},2,"uuid-2",30,40,4,0]"#
        let d = try #require(try DevalueDecoder.parse(feed) as? [String: Any])
        #expect(d["nextCursor"] as? String == "20|123")
        let items = try #require(d["items"] as? [Any])
        #expect(items.count == 2)
        let first = try #require(items[0] as? [String: Any])
        #expect((first["id"] as? NSNumber)?.intValue == 1)
        #expect(first["url"] as? String == "uuid-1")
        #expect((first["nsfwLevel"] as? NSNumber)?.intValue == 1)
        #expect(first["type"] as? String == "image")
        #expect(first["stats"] is NSNull)
        let user = try #require(first["user"] as? [String: Any])
        #expect(user["username"] as? String == "alice")
        #expect(user["image"] is NSNull)
        let second = try #require(items[1] as? [String: Any])
        #expect((second["id"] as? NSNumber)?.intValue == 2)
        #expect((second["nsfwLevel"] as? NSNumber)?.intValue == 4)
    }

    // MARK: Real production bytes

    @Test func decodesRealCivitaiFeedResponse() throws {
        // The Swift port must reproduce devalue's own output on the exact bytes
        // civitai.com returned (ground truth captured with devalue 5.8.1).
        let d = try #require(try DevalueDecoder.parse(LiveDevalueFeedFixture.resultData) as? [String: Any])
        #expect(d["nextCursor"] as? String == "20|1784469016010")
        let items = try #require(d["items"] as? [Any])
        #expect(items.count == 20)
        let first = try #require(items.first as? [String: Any])
        #expect((first["id"] as? NSNumber)?.intValue == 137199345)
        #expect(first["url"] as? String == "39565725-51c8-41f1-8c7c-a933f40c1bef")
        #expect(first["type"] as? String == "image")
        #expect((try #require(first["user"] as? [String: Any]))["username"] as? String == "Jio_R")
        let last = try #require(items.last as? [String: Any])
        #expect((last["id"] as? NSNumber)?.intValue == 137344182)
    }

    // MARK: Errors

    @Test func throwsOnEmptyArray() {
        #expect(throws: (any Error).self) { try DevalueDecoder.parse("[]") }
    }

    @Test func throwsOnInvalidJSON() {
        #expect(throws: (any Error).self) { try DevalueDecoder.parse("not json") }
    }
}

/// Tests for the union-READ normalizer that converts a devalue tRPC envelope into
/// the superjson-shaped `{ "json": … }` envelope the app's decoders expect, while
/// leaving an already-superjson envelope untouched.
@Suite struct TRPCEnvelopeNormalizeTests {

    @Test func convertsDevalueEnvelopeToSuperjsonShape() throws {
        // payload = { items: [ { id: 1 } ], nextCursor: null }
        let devalue = #"[{"result":{"data":"[{\"items\":1,\"nextCursor\":4},[2],{\"id\":3},1,null]"}}]"#
        let out = TRPCEnvelope.normalize(Data(devalue.utf8))

        let top = try #require(try JSONSerialization.jsonObject(with: out) as? [Any])
        let result = try #require((top.first as? [String: Any])?["result"] as? [String: Any])
        let dataField = try #require(result["data"] as? [String: Any])
        let json = try #require(dataField["json"] as? [String: Any])
        let items = try #require(json["items"] as? [Any])
        #expect(items.count == 1)
        #expect(((items[0] as? [String: Any])?["id"] as? NSNumber)?.intValue == 1)
        #expect(json["nextCursor"] is NSNull)
    }

    @Test func leavesSuperjsonEnvelopeUnchanged() {
        let input = Data(#"[{"result":{"data":{"json":{"items":[],"nextCursor":null}}}}]"#.utf8)
        #expect(TRPCEnvelope.normalize(input) == input)
    }

    @Test func failsOpenOnNonEnvelopeJSON() {
        let junk = Data(#"{"not":"a batch"}"#.utf8)
        #expect(TRPCEnvelope.normalize(junk) == junk)
    }
}
