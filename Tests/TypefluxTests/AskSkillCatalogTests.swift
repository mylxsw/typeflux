@testable import Typeflux
import XCTest

final class AskSkillCatalogTests: XCTestCase {
    private let entries = [AskSkillCatalogEntry(name: "notes", description: "Summarize meetings"),
                           AskSkillCatalogEntry(name: "translate", description: "Translate text")]

    func testScopesCatalogWithoutLeakingOtherSkillsOrChangingOtherTools() throws {
        let all = try XCTUnwrap(AskSkillCatalog.definition(entries))
        let other = AskToolDefinition(
            name: "files",
            description: "Read files",
            parameters: JSONValue(data: Data(#"{"type":"object"}"#.utf8))
        )
        let scoped = AskSkillCatalog.applying([entries[0]], to: [other, all])
        XCTAssertEqual(scoped.first, other)
        let skill = try XCTUnwrap(scoped.last)
        XCTAssertTrue(skill.description.contains("Summarize meetings"))
        XCTAssertFalse(skill.description.contains("Translate text"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: skill.parameters.data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["name"]?["enum"] as? [String], ["notes"])
        XCTAssertEqual(AskSkillCatalog.applying([], to: scoped), [other])
        XCTAssertEqual(AskSkillCatalog.applying(nil, to: [all, other]), [all, other])
        XCTAssertEqual(AskSkillCatalog.applying(entries, to: [other]), [other])
        XCTAssertEqual(AskSkillCatalog.applying(entries, to: [other], allowAdding: true).last, all)
    }

    func testFiftySkillsFitTheAPIDescriptionBudgetWithoutDroppingNames() throws {
        let catalog = (0 ..< 50).map { AskSkillCatalogEntry(name: String(repeating: "s", count: 60) + String($0),
                                                            description: String(repeating: "会议纪要", count: 75)) }
        let tool = try XCTUnwrap(AskSkillCatalog.definition(catalog))
        XCTAssertLessThanOrEqual(tool.description.utf8.count, 8000)
        for entry in catalog {
            XCTAssertTrue(tool.description.contains(entry.name))
        }
        XCTAssertNil(AskSkillCatalog.definition([]))
    }

    func testSkillCallsRespectTheLatestCatalog() {
        func call(_ name: String, args: String) -> AskToolCall {
            .init(id: "call", type: "function", function: .init(name: name, arguments: args))
        }
        XCTAssertTrue(AskSkillCatalog.permits(call("skill", args: #"{"name":"notes"}"#), catalog: entries))
        XCTAssertFalse(AskSkillCatalog.permits(call("skill", args: #"{"name":"other"}"#), catalog: entries))
        XCTAssertFalse(AskSkillCatalog.permits(call("skill", args: "bad JSON"), catalog: entries))
        XCTAssertFalse(AskSkillCatalog.permits(call("skill", args: #"{"name":"notes"}"#), catalog: []))
        XCTAssertTrue(AskSkillCatalog.permits(call("skill", args: #"{"name":"other"}"#), catalog: nil))
        XCTAssertTrue(AskSkillCatalog.permits(call("files", args: "{}"), catalog: []))
    }

    func testAllNoneAndSubsetDraftsAndCatalogsRoundTrip() throws {
        let selections: [[String]?] = [nil, [], ["notes"]]
        for names in selections {
            var draft = AskDraft()
            draft.skills = names
            let decoded = try AskCoding.decoder().decode(AskDraft.self, from: AskCoding.encoder().encode(draft))
            XCTAssertEqual(decoded.skills, names)
        }
        let catalogs: [[AskSkillCatalogEntry]?] = [nil, [], entries]
        for catalog in catalogs {
            let message = AskMessage(id: "q", role: "user", text: "Hello", createdAt: Date(), skillCatalog: catalog)
            let decoded = try AskCoding.decoder().decode(AskMessage.self, from: AskCoding.encoder().encode(message))
            XCTAssertEqual(decoded.skillCatalog, catalog)
            let request = AskSendRequest(id: "q", deviceId: "d", text: "Hello", tools: [], skillCatalog: catalog)
            let steer = AskSteerRequest(runId: "run", message: request)
            let restored = try AskCoding.decoder().decode(AskSteerRequest.self, from: AskCoding.encoder().encode(steer))
            XCTAssertEqual(restored.skillCatalog, catalog)
        }
    }
}
