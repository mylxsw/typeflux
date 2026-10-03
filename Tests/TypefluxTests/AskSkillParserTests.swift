import Foundation
@testable import Typeflux
import XCTest

final class AskSkillParserTests: XCTestCase {
    private func parse(_ header: String, body: String = "Do the task.") throws -> AskSkill {
        try AskSkillParser.parse("---\n" + header + "\n---\n" + body, fallbackName: "Fallback Name")
    }

    func testQuotedPlainAndMultilineScalars() throws {
        let quoted = try parse("name: 'Writer''s kit'\ndescription: \"Explain: \\\"hello\\\" # text\" # comment")
        XCTAssertEqual(quoted.name, "writer-s-kit")
        XCTAssertEqual(quoted.description, "Explain: \"hello\" # text")
        XCTAssertEqual(try parse("description: Read https://example.com/a#b # comment").description,
                       "Read https://example.com/a#b")
        XCTAssertEqual(
            try parse("description: >-\n  First line:\n  second line").description,
            "First line: second line"
        )
        XCTAssertEqual(try parse("description: |-\n  First\n  ---\n  Last").description, "First\n---\nLast")
        XCTAssertEqual(try parse("description: |\n  First\n  Last").description, "First\nLast\n")
        XCTAssertEqual(try parse("description: >-\n  First\n\n  Paragraph").description, "First\nParagraph")
        XCTAssertEqual(try parse("description: >-\n  First\n    indented\n  Last").description,
                       "First\n  indented\nLast")
    }

    func testMetadataPermissionListsAndUnknownScalarFields() throws {
        let skill = try parse("""
        name: Review
        metadata:
          author: Someone
          version: 2
        version: 1.2
        compatibility: macOS
        allowed-tools: [Read, 'Bash(git:*)']
        permissions:
          - browser.write
          - files.read
        """)
        XCTAssertEqual(skill.version, "1.2")
        XCTAssertEqual(skill.declaredPermissions, ["Read", "Bash(git:*)", "browser.write", "files.read"])
        XCTAssertEqual(try parse("allowed-tools: Read Write").declaredPermissions, ["Read Write"])
        XCTAssertEqual(try parse("permissions: []").declaredPermissions, [])
        XCTAssertEqual(try parse("description: ''").description, "Do the task.")
        XCTAssertEqual(try parse("").name, "fallback-name")
    }

    func testPlainDocumentsFallbackLimitsAndLineEndings() throws {
        let plain = try AskSkillParser.parse("# Heading\nActual description\nText", fallbackName: "Local Skill")
        XCTAssertEqual(plain.name, "local-skill")
        XCTAssertEqual(plain.description, "Actual description")
        XCTAssertEqual(try AskSkillParser.parse("# Heading", fallbackName: "Title").description, "title")
        let windows = try AskSkillParser.parse("\u{FEFF}---\r\nname: Windows\r\n...\r\nBody", fallbackName: "x")
        XCTAssertEqual(windows.name, "windows")
        XCTAssertEqual(windows.body, "Body")
        let long = try parse(
            "description: " + String(repeating: "x", count: 400),
            body: String(repeating: "b", count: 21000)
        )
        XCTAssertEqual(long.description.count, AskSkillLibrary.maximumDescriptionCharacters)
        XCTAssertEqual(long.body.count, AskSkillLibrary.maximumBodyCharacters)
    }

    func testRejectsMalformedFrontmatterInsteadOfTreatingItAsInstructions() {
        for text in [
            "---\nname: x\nBody",
            "---\nname: [broken\n---\nbody",
            "---\ndescription: 'open\n---\nbody",
            "---\nname: a\nname: b\n---\nbody",
            "---\nmetadata: {x: a, x: b}\n---\nbody"
        ] {
            XCTAssertThrowsError(try AskSkillParser.parse(text, fallbackName: "x"))
            XCTAssertNil(AskSkillLibrary.parse(text, fallbackName: "x"))
        }
    }

    func testRejectsUnsupportedStructuresAndDuplicateFields() {
        for header in [
            "name: [a, b]", "description: {text: x}", "metadata: value", "metadata: {nested: {x: y}}",
            "unknown: [a, b]", "permissions: [{tool: write}]", "permissions: {tool: write}",
            "? [complex, key]\n: value",
            "name: &name foo\ndescription: *name", "description: !!binary SGVsbG8=", "name: !custom foo",
            "<<: {name: merged}", "- name: list", "description: " + String(repeating: "x", count: 33000)
        ] {
            XCTAssertThrowsError(try parse(header), header) { error in
                XCTAssertEqual(error as? AskSkillParser.Failure, .unsupported, header)
            }
        }
    }

    func testInvalidNameAndEmptyBodyFailExplicitly() {
        for header in ["name: ''", "name: ---", "name: 日本語", "name: " + String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try parse(header)) { error in
                XCTAssertEqual(error as? AskSkillParser.Failure, .invalidSkill)
            }
        }
        XCTAssertThrowsError(try parse("name: valid", body: " \n "))
        XCTAssertNotEqual(AskSkillParser.Failure.malformed.localizedDescription, "ask.skills.parse.malformed")
    }
}
