@testable import Typeflux
import XCTest

final class MCPInputValidatorTests: XCTestCase {
    private func schema(_ object: [String: Any]) throws -> MCPObjectSchema {
        try JSONDecoder().decode(MCPObjectSchema.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func validate(_ arguments: String, _ object: [String: Any]) throws {
        _ = try MCPInputValidator.validate(arguments: arguments, schema: schema(object))
    }
    func testRawRootSchemaSurvivesAdapterAndCodecs() throws {
        let raw = ##"{"type":"object","oneOf":[{"required":["count"]},{"required":["name"]}],"$defs":{"count":{"type":"integer","minimum":1,"maximum":5}},"properties":{"count":{"$ref":"#/$defs/count"},"name":{"enum":["a","b"]}},"additionalProperties":false,"x-vendor":{"zero":0,"one":1,"flag":true,"nested":[null,2.5]}}"##
        let value = try JSONDecoder().decode(MCPObjectSchema.self, from: Data(raw.utf8))
        let adapter = MCPToolAdapter(client: MockMCPClient(), toolDef: .init(name: "t", description: nil, inputSchema: value))
        let original = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! NSDictionary
        XCTAssertEqual(original, adapter.definition.inputSchema.jsonObject as NSDictionary)
        XCTAssertEqual(original, try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
        // Vendor validation is unknown; retaining it must not imply enforcement.
        XCTAssertThrowsError(try MCPInputValidator.check(schema: value))
        var supported = original as! [String: Any]; supported.removeValue(forKey: "x-vendor")
        try validate(#"{"count":3}"#, supported)
        try validate(#"{"name":"a"}"#, supported)
        for invalid in [#"{"count":0}"#, #"{"count":6}"#, #"{"count":true}"#, #"{"count":2,"name":"a"}"#, #"{"name":"c"}"#, #"{"name":"a","extra":1}"#] {
            XCTAssertThrowsError(try validate(invalid, supported))
        }
    }
    func testConstraintsAndFieldPaths() throws {
        let object: [String: Any] = ["type":"object", "required":["n"], "additionalProperties":false,
            "properties":["n":["type":"number", "exclusiveMinimum":0, "exclusiveMaximum":10, "multipleOf":0.5],
                          "s":["type":"string", "minLength":2,"maxLength":3],
                          "a":["type":"array","minItems":1,"maxItems":3,"uniqueItems":true,"items":["type":"integer"]]],
            "minProperties":1,"maxProperties":3]
        try validate(#"{"n":1.5,"s":"你好","a":[1,2]}"#,object)
        for bad in [#"{}"#, #"{"n":0}"#, #"{"n":10}"#, #"{"n":0.3}"#, #"{"n":2,"s":"x"}"#, #"{"n":2,"s":"abcd"}"#, #"{"n":2,"a":[]}"#, #"{"n":2,"a":[1,1]}"#, #"{"n":2,"a":[1,2,3,4]}"#, #"{"n":2,"a":[true]}"#, #"{"n":2,"x":1,"y":1,"z":1}"#] { XCTAssertThrowsError(try validate(bad,object),bad) }
        do { try validate(#"{"n":2,"a":["wrong"]}"#,object); XCTFail() }
        catch let error as MCPInputError { XCTAssertEqual(error.path,"$/a/0"); XCTAssertFalse(error.localizedDescription.contains("wrong")) }
    }
    func testCombinatorsAndPrimitiveEquality() throws {
        let s: [String: Any] = ["type":"object", "properties":["v":["anyOf":[["type":"null"],["type":"boolean"],["type":"array"]], "not":["const":false]]], "allOf":[["required":["v"]]]]
        try validate(#"{"v":null}"#,s); try validate(#"{"v":true}"#,s); try validate(#"{"v":[]}"#,s)
        XCTAssertThrowsError(try validate(#"{"v":false}"#,s)); XCTAssertThrowsError(try validate(#"{"v":1}"#,s)); XCTAssertThrowsError(try validate("{}",s))
        try validate(#"{"v":{"a":[1,true,null]}}"#,["type":"object","properties":["v":["const":["a":[1,true,NSNull()]]]]])
        XCTAssertThrowsError(try validate(#"{"v":{"a":[true,1,null]}}"#,["type":"object","properties":["v":["const":["a":[1,true,NSNull()]]]]]))
        try validate(#"{"v":1}"#,["type":"object","properties":["v":["type":["integer","null"]]]])
        try validate(#"{"extra":3}"#,["type":"object","additionalProperties":["type":"number"]])
        try validate(#"{"v":2}"#,["type":"object","properties":["v":true]])
        XCTAssertThrowsError(try validate(#"{"v":2}"#,["type":"object","properties":["v":false]]))
    }
    func testOfflineReferencesAndComplexityFailClosed() throws {
        try validate(#"{"v":"yes"}"#,["type":"object","$defs":["a/b~c":["enum":["yes"]]],"properties":["v":["$ref":"#/$defs/a~1b~0c"]]])
        for ref in ["https://example.invalid/schema", "file:///etc/passwd", "#/$defs/missing", "#anchor"] {
            XCTAssertThrowsError(try validate("{}",["type":"object","$ref":ref]))
        }
        XCTAssertThrowsError(try validate("{}",["type":"object","$ref":"#"]))
        var deep: [String: Any] = ["type":"object"]
        for _ in 0..<66 { deep = ["type":"object","properties":["x":deep]] }
        XCTAssertThrowsError(try validate("{}",deep))
        XCTAssertThrowsError(try validate(String(repeating:" ",count:256001),["type":"object"]))
        for input in ["[]","null","true","not json"] { XCTAssertThrowsError(try validate(input,["type":"object"])) }
    }
    func testUnsupportedAndMalformedConstraintsAreRejected() throws {
        let cases: [[String: Any]] = [["pattern":".*"],["format":"email"],["$schema":"http://json-schema.org/draft-07/schema#"],["$schema":1],["type":"nope"],["required":false],["enum":[]],["minimum":true],["multipleOf":0],["maxItems":-1],["minLength":0.5],["uniqueItems":1],["properties":[]],["oneOf":[]],["anyOf":1],["allOf":[3]],["items":3],["$ref":1],["$id":"https://example.invalid"]]
        for item in cases { var root:[String:Any] = ["type":"object"]; root.merge(item) { _,new in new }; XCTAssertThrowsError(try validate("{}",root),String(describing:item)) }
        try validate("{}",["type":"object","$schema":"https://json-schema.org/draft/2020-12/schema","description":"annotation","default":[:]])
    }
    func testInvalidArgumentsNeverReachMCP() async throws {
        let client = MockMCPClient(); try await client.connect()
        let adapter = MCPToolAdapter(client:client,toolDef:.init(name:"t",description:nil,inputSchema:try schema(["type":"object","properties":["x":["type":"integer","minimum":1]],"required":["x"]])))
        for arguments in ["{}",#"{"x":0}"#,"bad"] {
            do { _ = try await adapter.call(arguments:arguments); XCTFail() } catch { XCTAssertTrue(error is MCPInputError) }
        }
        let before = await client.callToolCallCount; XCTAssertEqual(before,0)
        _ = try await adapter.call(arguments:#"{"x":1}"#)
        let after = await client.callToolCallCount; XCTAssertEqual(after,1)
    }
}
