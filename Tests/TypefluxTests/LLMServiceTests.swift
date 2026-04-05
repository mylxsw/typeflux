@testable import Typeflux
import XCTest

final class LLMServiceTests: XCTestCase {
    // MARK: - AnySendable

    func testStringConversion() {
        let value = AnySendable.string("hello")
        XCTAssertEqual(value.foundationValue as? String, "hello")
    }

    func testIntConversion() {
        let value = AnySendable.int(42)
        XCTAssertEqual(value.foundationValue as? Int, 42)
    }

    func testDoubleConversion() {
        let value = AnySendable.double(3.14)
        XCTAssertEqual(value.foundationValue as? Double, 3.14)
    }

    func testBoolConversion() {
        let trueValue = AnySendable.bool(true)
        XCTAssertEqual(trueValue.foundationValue as? Bool, true)

        let falseValue = AnySendable.bool(false)
        XCTAssertEqual(falseValue.foundationValue as? Bool, false)
    }

    func testNullConversion() {
        let value = AnySendable.null
        XCTAssertTrue(value.foundationValue is NSNull)
    }

    func testArrayConversion() {
        let value = AnySendable.array([.string("a"), .int(1), .bool(true)])
        let array = value.foundationValue as? [Any]
        XCTAssertNotNil(array)
        XCTAssertEqual(array?.count, 3)
        XCTAssertEqual(array?[0] as? String, "a")
        XCTAssertEqual(array?[1] as? Int, 1)
        XCTAssertEqual(array?[2] as? Bool, true)
    }

    func testObjectConversion() {
        let value = AnySendable.object([
            "name": .string("test"),
            "count": .int(5),
        ])
        let dict = value.foundationValue as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["name"] as? String, "test")
        XCTAssertEqual(dict?["count"] as? Int, 5)
    }

    func testNestedArrayInObject() {
        let value = AnySendable.object([
            "items": .array([.string("x"), .string("y")]),
        ])
        let dict = value.foundationValue as? [String: Any]
        let items = dict?["items"] as? [Any]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0] as? String, "x")
    }

    func testNestedObjectInArray() {
        let value = AnySendable.array([
            .object(["key": .string("value")]),
        ])
        let array = value.foundationValue as? [Any]
        let nested = array?.first as? [String: Any]
        XCTAssertEqual(nested?["key"] as? String, "value")
    }

    func testDeeplyNestedStructure() {
        let value = AnySendable.object([
            "level1": .object([
                "level2": .array([
                    .object(["level3": .string("deep")]),
                ]),
            ]),
        ])
        let dict = value.foundationValue as? [String: Any]
        let level1 = dict?["level1"] as? [String: Any]
        let level2 = level1?["level2"] as? [Any]
        let level3 = (level2?.first as? [String: Any])?["level3"] as? String
        XCTAssertEqual(level3, "deep")
    }

    // MARK: - LLMJSONSchema

    func testSchemaJsonObject() {
        let schema = LLMJSONSchema(
            name: "test",
            schema: [
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                ]),
            ],
        )

        let jsonObj = schema.jsonObject
        XCTAssertEqual(jsonObj["type"] as? String, "object")
        let props = jsonObj["properties"] as? [String: Any]
        XCTAssertNotNil(props?["name"])
    }

    func testSchemaDefaultStrict() {
        let schema = LLMJSONSchema(name: "test", schema: [:])
        XCTAssertTrue(schema.strict)
    }

    func testSchemaCustomStrict() {
        let schema = LLMJSONSchema(name: "test", schema: [:], strict: false)
        XCTAssertFalse(schema.strict)
    }
}
