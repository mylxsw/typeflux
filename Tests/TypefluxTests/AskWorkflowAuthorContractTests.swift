import Foundation
import Testing
@testable import Typeflux

@Suite("Workflow author tool contract")
@MainActor
struct AskWorkflowAuthorContractTests {
    private func call(_ name: String, _ arguments: [String: Any]) throws -> AskToolCall {
        .init(id: UUID().uuidString, function: .init(name: name, arguments:
            String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)))
    }

    @Test func malformedWeatherProposalReportsBothArraysAndCanBeCorrected() async throws {
        let fixture = try AskWorkflowFixture()
        let store = AskWorkflowAuthoringStore(workflows: fixture.store,
            root: fixture.home.appendingPathComponent("authoring"),
            staging: .init(root: fixture.home.appendingPathComponent("previews")), owner: { "alice" })
        let session = try store.start("weather", name: "Weather", workflowID: nil)
        defer { session.close() }
        let original = session.draft, revision = session.revision
        var manifest: [String: Any] = [
            "schema": 1, "id": "local.weather", "name": "Weather",
            "keywords": ["item": [["keyword": "weather"], ["keyword": "wttr"]]],
            "command": ["runtime": "zsh", "script": "main.sh", "args": ["item": "{query}"]],
            "output": "markdown"
        ]
        let files = [["path": "main.sh", "content": "#!/bin/zsh\nprint -r -- \"$1\"\n"]]
        let tools = AskWorkflowAuthorTools()
        let rejected = await tools.execute(try call("workflow_propose", [
            "summary": "Weather", "manifest": manifest, "files": files
        ]), host: session)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(rejected.content.utf8)) as? [String: Any])
        let problems = try #require(report["problems"] as? [[String: Any]])
        #expect(rejected.isError && report["draftUpdated"] as? Bool == false)
        #expect(Set(problems.compactMap { $0["field"] as? String }) == ["keywords", "command.args"])
        #expect(problems.allSatisfy { $0["actual"] as? String == "object" })
        #expect(problems.allSatisfy { ($0["message"] as? String)?.contains("JSON array") == true })
        #expect(session.draft == original && session.revision == revision && session.proposals.isEmpty)

        manifest["keywords"] = [["keyword": "weather"], ["keyword": "wttr"]]
        manifest["command"] = ["runtime": "zsh", "script": "main.sh", "args": ["{query}"]]
        let accepted = await tools.execute(try call("workflow_propose", [
            "summary": "Weather", "manifest": manifest, "files": files
        ]), host: session)
        #expect(!accepted.isError && accepted.content.contains("\"draftUpdated\":true"))
        #expect(session.revision != revision && session.draft.manifest?.keywords.count == 2)
        #expect(session.draft.files["main.sh"] == files[0]["content"])
        session.tester.searchPath = { "/bin:/usr/bin" }
        let tested = await tools.execute(try call("workflow_test", ["inputs": [["query": "Singapore"]]]), host: session)
        #expect(!tested.isError && session.lastTestResult?.stdout == "Singapore\n")
        #expect(fixture.store.workflows.isEmpty)
    }

    @Test func invalidDraftIsNotReportedAsUserRefusal() async throws {
        let fixture = try AskWorkflowFixture()
        let store = AskWorkflowAuthoringStore(workflows: fixture.store,
            root: fixture.home.appendingPathComponent("authoring"),
            staging: .init(root: fixture.home.appendingPathComponent("previews")), owner: { "alice" })
        let session = try store.start("weather", name: "Weather", workflowID: nil)
        defer { session.close() }
        let result = await AskWorkflowAuthorTools().execute(
            try call("workflow_test", ["inputs": [["query": "Singapore"]]]), host: session)
        #expect(result.isError && result.content.contains("invalid_draft"))
        #expect(result.content.contains("keywords") && result.content.contains("command.script"))
        #expect(!result.content.contains("did not allow"))
        #expect(session.preview == nil && !session.isRunning)
    }

    @Test func cancelledAndUnavailableRunsHaveDifferentReasonsFromDecline() {
        #expect(AskWorkflowAuthoringTestFailure.declined.content.contains("did not allow"))
        #expect(!AskWorkflowAuthoringTestFailure.cancelled.content.contains("did not allow"))
        #expect(AskWorkflowAuthoringTestFailure.unavailable("File changed").content.contains("File changed"))
        #expect(!AskWorkflowAuthoringTestFailure.unavailable("File changed").content.contains("did not allow"))
    }

    @Test func saveDoesNotAskUserToInstallAnInvalidStarter() async throws {
        let fixture = try AskWorkflowFixture()
        let store = AskWorkflowAuthoringStore(workflows: fixture.store,
            root: fixture.home.appendingPathComponent("authoring"),
            staging: .init(root: fixture.home.appendingPathComponent("previews")), owner: { "alice" })
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: fixture.settings.defaults)),
                                  settings: fixture.settings, owner: { "alice" })
        tools.workflowAuthoring = store
        _ = try store.start("weather", name: "Weather", workflowID: nil)
        let result = try await tools.execute(call("workflow_save", [:]), conversationId: "weather")
        #expect(result.isError && result.content.contains("invalid_draft"))
        #expect(result.content.contains("workflow_propose") && !result.content.contains("choose Save"))
        #expect(fixture.store.workflows.isEmpty)
    }

    @Test func nestedTypesAndOptionalFieldsAreCheckedWithoutDroppingExtensions() {
        var manifest = AskWorkflowFixture.inline("local.test", keyword: "test", script: "print test")
        manifest["futureExtension"] = ["item": "preserve me"]
        manifest["description"] = NSNull()
        #expect(AskWorkflowAuthorManifestSchema.problems(manifest).isEmpty)
        manifest["keywords"] = [["keyword": "test", "options": ["city": 2]], ["title": "missing keyword"]]
        manifest["output"] = ["display": "text", "onSuccess": ["item": ["action": "copy", "value": "{output}"]]]
        let fields = Set(AskWorkflowAuthorManifestSchema.problems(manifest).compactMap { $0["field"] as? String })
        #expect(fields == ["keywords[0].options.city", "keywords[1].keyword", "output.onSuccess"])
    }

    @Test func toolSchemaDescribesNestedArraysAndOutputActions() throws {
        let definition = try #require(AskWorkflowAuthorTools.definitions.first { $0.name == "workflow_propose" })
        let schema = try #require(try JSONSerialization.jsonObject(with: definition.parameters.data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let manifest = try #require(properties["manifest"] as? [String: Any])
        let fields = try #require(manifest["properties"] as? [String: [String: Any]])
        #expect(fields["keywords"]?["type"] as? String == "array")
        let command = try #require(fields["command"]?["properties"] as? [String: [String: Any]])
        #expect(command["args"]?["type"] as? String == "array")
        let output = try #require(fields["output"]?["properties"] as? [String: [String: Any]])
        #expect(output["onSuccess"]?["type"] as? String == "array")
    }
}
