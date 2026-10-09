import Testing
@testable import Typeflux

@Suite("Ask screenshot consent", .exclusiveUIState)
@MainActor
struct AskScreenshotApprovalTests {
    private func call(_ name: String = "computer", arguments: String = "{\"action\":\"screenshot\"}") -> AskToolCall {
        .init(id: "shot", type: "function", function: .init(name: name, arguments: arguments))
    }

    @Test(arguments: [true, false])
    func submittedScreenshotChoiceApprovesCaptureWithoutPrompt(hasCapturedImage: Bool) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(call())
        f.model.launcherDraft.text = "Look at my screen"
        f.model.launcherDraft.includeScreenshot = true
        if hasCapturedImage { f.model.launcherDraft.screenshot = "data:image/jpeg;base64,YQ==" }
        f.model.submitLauncher()
        // Changes to the composer after sending must not change that submission's consent.
        f.model.launcherDraft.includeScreenshot = false
        try await f.wait { f.model.busyIds.isEmpty || !f.model.pendingApprovals.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(f.tools.executions == 1)
        #expect(await f.api.results.first?.isError == false)
    }

    @Test func uncheckedScreenshotStillRequiresApprovalEvenWithCachedImage() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(call())
        f.model.launcherDraft.text = "Answer my question"
        f.model.launcherDraft.screenshot = "cached image"
        f.model.launcherDraft.includeScreenshot = false
        f.model.submitLauncher()
        f.model.launcherDraft.includeScreenshot = true
        try await f.wait { !f.model.pendingApprovals.isEmpty || f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.count == 1)
        #expect(f.tools.executions == 0)
        let id = try #require(f.model.selected?.id)
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.results.first?.isError == true)
    }

    @Test(arguments: [
        ("computer", "{\"action\":\"click\",\"x\":0.5,\"y\":0.5}"),
        ("computer", "{\"action\":\"type\",\"text\":\"hello\"}"),
        ("computer", "{\"action\":\"key\",\"key\":\"return\"}"),
        ("computer", "{\"action\":\"scroll\",\"amount\":1}"),
        ("mcp_screenshot", "{\"action\":\"screenshot\"}"),
        ("computer", "not json"),
        ("computer", "{}")
    ])
    func screenshotConsentDoesNotApproveOtherTools(name: String, arguments: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(call(name, arguments: arguments))
        f.model.launcherDraft.text = "Help with this screen"
        f.model.launcherDraft.includeScreenshot = true
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty || f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.count == 1)
        #expect(f.tools.executions == 0)
        let id = try #require(f.model.selected?.id)
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }

    @Test func consentIsScopedToEachSubmissionIncludingFollowUps() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(call())
        f.model.launcherDraft = AskDraft(text: "First question", screenshot: "data:image/jpeg;base64,YQ==")
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty || !f.model.pendingApprovals.isEmpty }
        #expect(f.tools.executions == 1)
        let id = try #require(f.model.selected?.id)
        #expect(!f.model.draft.includeScreenshot)
        f.model.draft.text = "Follow up without screenshot"
        f.model.submitDraft()
        try await f.wait { !f.model.pendingApprovals.isEmpty || f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.count == 1)
        #expect(f.tools.executions == 1)
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }

        f.model.draft.text = "Follow up with screenshot"
        f.model.draft.includeScreenshot = true
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty || !f.model.pendingApprovals.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(f.tools.executions == 2)
    }

    @Test func retryPreservesTheOriginalSubmissionConsent() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(call())
        await f.api.setFailSend(true)
        f.model.launcherDraft.text = "Look at the screen"
        f.model.launcherDraft.includeScreenshot = true
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        await f.api.setFailSend(false)
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty || !f.model.pendingApprovals.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(f.tools.executions == 1)
    }

    @Test func restoredConversationImageDoesNotGrantScreenshotConsent() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let tool = call()
        let value = AskConversation(id: "history", title: "History", revision: 1, updatedAt: .now,
            messages: [.init(id: "user", role: "user", text: "Old question", image: "old image", createdAt: .now)],
            run: .init(id: "old-run", deviceId: "device", status: "waiting_tool", steps: 1,
                       updatedAt: .now, tools: [], pending: [tool]))
        await f.api.seed(value)
        await f.model.select(value.id)
        f.model.resume()
        try await f.wait { !f.model.pendingApprovals.isEmpty || f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.count == 1)
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: value.id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }


    @Test func consentDoesNotApplyToANewerMessageFromAnotherDevice() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Original question with screenshot"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        var value = try #require(f.model.selected)
        value.messages.append(.init(id: "other-user-message", role: "user", text: "Another question", createdAt: .now))
        value.run = .init(id: "new-run", deviceId: "device", status: "waiting_tool", steps: 1,
                          updatedAt: .now, tools: [], pending: [call()])
        value.revision += 1
        await f.api.seed(value)
        await f.model.select(value.id, reload: true)
        f.model.resume()
        try await f.wait { !f.model.pendingApprovals.isEmpty || f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.count == 1)
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: value.id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }

}
