import Testing
@testable import Typeflux

@Suite("Ask screenshot consent", .exclusiveUIState)
@MainActor
struct AskScreenshotApprovalTests {
    private func call(_ name: String = "computer", arguments: String = #"{"action":"screenshot"}"#) -> AskToolCall {
        .init(id: "shot", function: .init(name: name, arguments: arguments))
    }

    @Test(arguments: [true, false])
    func standardCaptureFollowsThePermissionTableRegardlessOfAttachmentChoice(_ includeScreenshot: Bool) async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        await f.api.setTool(call())
        f.model.launcherDraft = AskDraft(text: "Read screen", includeScreenshot: includeScreenshot)
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty || !f.model.pendingApprovals.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(f.tools.executions == 1)
    }

    @Test func screenshotCanBeSetToAskWithoutChangingOtherReadPermissions() async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        f.model.modelLibrary.settings.setToolPermission(.ask, entry: AskToolAuthorization.entry(for: call()), mode: .standard)
        await f.api.setTool(call())
        f.model.launcherDraft = AskDraft(text: "Read screen", includeScreenshot: true)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(f.model.automaticallyApproves(call("computer", arguments: #"{"action":"inspect"}"#), risk: .read,
                                            conversationId: try #require(f.model.selectedId)))
        f.model.approve(conversationId: try #require(f.model.selectedId), allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }

    @Test(arguments: [
        ("computer", #"{"action":"click","x":0.5,"y":0.5}"#),
        ("computer", #"{"action":"type","text":"hello"}"#),
        ("computer", #"{"action":"key","key":"return"}"#),
        ("computer", #"{"action":"scroll","amount":1}"#),
        ("mcp_screenshot", #"{"action":"screenshot"}"#),
        ("computer", "not json"), ("computer", "{}")
    ])
    func screenshotPermissionDoesNotApproveOtherOperations(name: String, arguments: String) async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        await f.api.setTool(call(name, arguments: arguments))
        f.model.launcherDraft = AskDraft(text: "Help", includeScreenshot: true)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty || f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.count == 1)
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: try #require(f.model.selectedId), allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }

    @Test func strictCaptureStillRequiresApproval() async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        f.model.setPermissionMode(.strict, launcher: true)
        await f.api.setTool(call())
        f.model.launcherDraft = AskDraft(text: "Read screen", includeScreenshot: true)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: try #require(f.model.selectedId), allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }
}
