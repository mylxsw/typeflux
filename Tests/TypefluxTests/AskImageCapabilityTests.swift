import Foundation
import Testing
@testable import Typeflux

@Suite("Ask image capability", .serialized)
@MainActor
struct AskImageCapabilityTests {
    static let image = "data:image/jpeg;base64,YQ=="

    func fixture() async throws -> AskTestFixture {
        let f = try AskTestFixture()
        await f.model.prepareLauncher()
        await f.api.setCloudModels([
            .init(id: "default", name: "Default", vision: true),
            .init(id: "text", name: "Text", vision: false),
            .init(id: "vision", name: "Vision", vision: true),
            .init(id: "unknown", name: "Unknown")
        ])
        await f.model.modelLibrary.refresh(api: f.api, token: "token")
        return f
    }

    func conversation(_ id: String = "images", status: String = "failed", reference: String = "cloud:text") -> AskConversation {
        AskConversation(id: id, title: "Screen", revision: 1, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), messages: [
            .init(id: "shot", role: "tool", text: "Screen", image: Self.image, toolCallId: "capture", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        ], run: .init(id: "run-" + id, deviceId: "device", status: status, steps: 1, updatedAt: .now,
                     tools: [], pending: [], modelRef: reference), modelRef: reference)
    }

    @Test func capabilitiesHaveDistinctReasons() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let library = f.model.modelLibrary
        #expect(library.imageCapability("cloud:vision") == .supported)
        #expect(library.imageCapability("cloud:text") == .unsupported)
        #expect(library.imageCapability("cloud:unknown") == .unknown)
        #expect(library.imageCapability("missing") == .unavailable)
        #expect(AskImageCapability.supported.hint == nil)
        #expect(AskImageCapability.unsupported.hint != AskImageCapability.unknown.hint)
        #expect(AskImageCapability.unavailable.hint != nil)
    }

    @Test(arguments: [true, false])
    func switchingDetachesButPreservesDraftAndDoesNotReattach(launcher: Bool) async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = AskDraft(text: "Keep question", screenshot: Self.image, modelRef: "cloud:vision")
        if launcher { f.model.launcherDraft = value } else { f.model.draft = value }
        f.model.selectModel("cloud:text", launcher: launcher)
        let detached = launcher ? f.model.launcherDraft : f.model.draft
        #expect(!detached.includeScreenshot)
        #expect(detached.screenshot == Self.image)
        #expect(detached.text == value.text)
        #expect((launcher ? f.model.launcherScreenshotNotice : f.model.screenshotNotice) != nil)
        #expect(launcher ? f.model.canSendLauncher : f.model.canSend)
        f.model.selectModel("cloud:vision", launcher: launcher)
        #expect(!(launcher ? f.model.launcherDraft : f.model.draft).includeScreenshot)
        #expect((launcher ? f.model.launcherScreenshotNotice : f.model.screenshotNotice) == nil)
        #expect(f.model.modelLibrary.defaultReference == "cloud:default")
    }

    @Test(arguments: ["cloud:text", "cloud:unknown", "missing"])
    func restoredOrProgrammaticChoicesCannotBypassCapability(reference: String) async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft = AskDraft(text: "Question", screenshot: Self.image, modelRef: reference)
        f.model.draft = AskDraft(text: "Question", screenshot: Self.image, modelRef: reference)
        f.model.launcherDraft.includeScreenshot = true
        f.model.draft.includeScreenshot = true
        #expect(!f.model.launcherDraft.includeScreenshot)
        #expect(!f.model.draft.includeScreenshot)
        let calls = f.capture.calls
        await f.model.refreshScreenshot(launcher: true)
        await f.model.refreshScreenshot(launcher: false)
        #expect(f.capture.calls == calls)
    }

    @Test func textModelSendsTextWithoutScreenshot() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft = AskDraft(text: "Text only", screenshot: Self.image, modelRef: "cloud:text")
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        let sent = try #require(await f.api.sends.first)
        #expect(sent.image == nil)
        #expect(sent.text == "Text only")
        #expect(sent.modelRef == "cloud:text")
    }

    @Test func catalogChangesDisableExistingSelectionWithoutReenablingIt() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft = AskDraft(text: "Question", screenshot: Self.image, modelRef: "cloud:vision")
        await f.api.setCloudModels([.init(id: "vision", name: "Vision", vision: false)])
        await f.model.modelLibrary.refresh(api: f.api, token: "token")
        try await f.wait { !f.model.launcherDraft.includeScreenshot }
        #expect(f.model.launcherDraft.screenshot == Self.image)
        await f.api.setCloudModels([.init(id: "vision", name: "Vision", vision: true)])
        await f.model.modelLibrary.refresh(api: f.api, token: "token")
        #expect(!f.model.launcherDraft.includeScreenshot)
    }

    @Test func defaultChangesNormalizeBothDrafts() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        f.model.draft = AskDraft(text: "Question", screenshot: Self.image)
        f.model.modelLibrary.defaultReference = "cloud:text"
        try await f.wait { !f.model.draft.includeScreenshot && !f.model.launcherDraft.includeScreenshot }
        #expect(f.model.screenshotCapability(launcher: true) == .unsupported)
    }

    @Test func failedImageRecoveryHasStableProgressAndOnlyRetriesOnce() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        let target = try #require(f.model.imageRecoveryTarget)
        #expect(!f.model.canResumeImage)
        f.model.resume()
        #expect(f.model.busyIds.isEmpty)
        #expect(f.model.error != nil)
        await f.api.hold(value.id)
        f.model.resumeImage(target, reference: "cloud:vision")
        #expect(f.model.recoveringImage == target)
        #expect(f.model.imageRecoveryTarget == target)
        f.model.resumeImage(target, reference: "cloud:vision")
        await f.api.release(value.id)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.retryModels == ["cloud:vision"])
        #expect(f.model.recoveringImage == nil)
        #expect(f.model.imageRecoveryTarget == nil)
        #expect(f.model.selected?.messages == value.messages)
        #expect(f.tools.executions == 0)
        #expect(f.model.modelLibrary.defaultReference == "cloud:default")
    }

    @Test func stalePickerCannotRetryAnotherConversationOrRun() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        var value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        let target = try #require(f.model.imageRecoveryTarget)
        let other = conversation("other")
        await f.api.seed(other)
        await f.model.select(other.id)
        f.model.resumeImage(target, reference: "cloud:vision")
        #expect(f.model.modelReference(launcher: false) == "cloud:text")
        await f.model.select(value.id)
        value.run?.id = "new-run"; value.revision += 1
        await f.api.seed(value)
        await f.model.select(value.id, reload: true)
        f.model.resumeImage(target, reference: "cloud:vision")
        #expect(await f.api.retryModels.isEmpty)
        #expect(f.model.busyIds.isEmpty)
    }

    @Test func concurrentRecoveriesKeepIndependentProgress() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        for id in ["first", "second"] {
            let value = conversation(id)
            await f.api.seed(value)
            await f.model.select(id)
            let target = try #require(f.model.imageRecoveryTarget)
            await f.api.hold(id)
            f.model.resumeImage(target, reference: "cloud:vision")
        }
        #expect(f.model.recoveringImages.count == 2)
        await f.api.release("first")
        try await f.wait { !f.model.busyIds.contains("first") }
        #expect(f.model.recoveringImage?.conversationID == "second")
        #expect(f.model.recoveringImages.count == 1)
        await f.api.release("second")
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.recoveringImages.isEmpty)
    }

    @Test func manualModelChoiceKeepsRecoveryButDoesNotStartIt() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        f.model.resume()
        #expect(f.model.error != nil)
        f.model.selectModel("cloud:vision", launcher: false)
        #expect(f.model.error == nil)
        #expect(f.model.canResumeImage)
        #expect(f.model.imageRecoveryTarget != nil)
        #expect(await f.api.retryModels.isEmpty)
        f.model.draft.includeScreenshot = false
        #expect(f.model.requiresVision(launcher: false))
        #expect(f.model.selected?.messages == value.messages)
    }

    @Test func catalogFailureKeepsScreenshotAndRecoveryAvailable() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        let target = try #require(f.model.imageRecoveryTarget)
        await f.api.setFailModels(true)
        f.model.resumeImage(target, reference: "cloud:vision")
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.error != nil)
        #expect(f.model.imageRecoveryTarget == target)
        #expect(f.model.recoveringImage == nil)
        #expect(f.model.selected?.messages == value.messages)
        #expect(await f.api.retryModels.isEmpty)
        await f.api.setFailModels(false)
        f.model.resumeImage(target, reference: "cloud:vision")
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.error == nil)
        #expect(await f.api.retryModels == ["cloud:vision"])
    }

    @Test func noCompatibleModelsLeavesTaskAndScreenshotIntact() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        await f.api.setCloudModels([.init(id: "text", name: "Text", vision: false)])
        await f.model.modelLibrary.refresh(api: f.api, token: "token")
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        let target = try #require(f.model.imageRecoveryTarget)
        #expect(f.model.modelLibrary.selectableProviders(loggedIn: true, hasImage: true).isEmpty)
        f.model.resumeImage(target, reference: "cloud:text")
        #expect(!f.model.canResumeImage)
        #expect(f.model.selected?.messages == value.messages)
        #expect(await f.api.retryModels.isEmpty)
        #expect(f.model.modelReference(launcher: false) == "cloud:text")
    }

    @Test(arguments: ["waiting_tool", "running", "waiting_inference", "completed"])
    func nonterminalAndCompletedRunsDoNotOfferImageRetry(status: String) async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = conversation(status: status)
        await f.api.seed(value)
        await f.model.select(value.id)
        #expect(f.model.imageRecoveryTarget == nil)
    }

    @Test func unrelatedFailuresKeepGenericRetryAndCaptureStatusIsSpecific() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        var value = conversation(reference: "cloud:vision")
        await f.api.seed(value)
        await f.model.select(value.id)
        #expect(f.model.imageRecoveryTarget == nil)
        #expect(AskPresentation.toolStatusText(result: value.messages.first) == L("ask.image.captured"))
        value.messages = []; value.modelRef = "cloud:text"; value.run?.modelRef = "cloud:text"; value.revision += 1
        await f.api.seed(value)
        await f.model.select(value.id, reload: true)
        #expect(f.model.imageRecoveryTarget == nil)
    }
}
