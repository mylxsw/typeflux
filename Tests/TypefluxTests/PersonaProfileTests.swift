import XCTest
@testable import Typeflux

final class PersonaProfileTests: XCTestCase {

    func testIsSystemReturnsTrueForSystemKind() {
        let profile = PersonaProfile(name: "Built-in", prompt: "Be concise", kind: .system)
        XCTAssertTrue(profile.isSystem)
    }

    func testIsSystemReturnsFalseForCustomKind() {
        let profile = PersonaProfile(name: "My Persona", prompt: "Be formal", kind: .custom)
        XCTAssertFalse(profile.isSystem)
    }

    func testCodableRoundTrip() throws {
        let original = PersonaProfile(name: "Test", prompt: "Do great things", kind: .system)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersonaProfile.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.prompt, original.prompt)
        XCTAssertEqual(decoded.kind, .system)
    }

    func testDecodingWithoutKindDefaultsToCustom() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "name": "Legacy Persona",
            "prompt": "Old prompt"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(PersonaProfile.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Legacy Persona")
        XCTAssertEqual(decoded.kind, .custom)
    }

    func testDefaultInitUsesCustomKind() {
        let profile = PersonaProfile(name: "Default", prompt: "prompt")
        XCTAssertEqual(profile.kind, .custom)
    }

    func testEquatable() {
        let id = UUID()
        let a = PersonaProfile(id: id, name: "A", prompt: "p", kind: .custom)
        let b = PersonaProfile(id: id, name: "A", prompt: "p", kind: .custom)
        let c = PersonaProfile(name: "C", prompt: "p", kind: .custom)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
