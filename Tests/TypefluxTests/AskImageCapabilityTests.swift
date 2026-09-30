import Foundation
import Testing
@testable import Typeflux

@Suite("Ask image capability", .serialized)
@MainActor
struct AskImageCapabilityTests {
    static let image = "data:image/jpeg;base64,YQ=="

    @Test func restoringDraftWaitsForTheConversationModel() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        f.model.modelLibrary.defaultReference = "cloud:text"
        var value = conversation(reference: "cloud:vision")
        value.usage = .init(version: 1, since: value.updatedAt, historicalGap: false,
                            total: .init(calls: 1, pending: 1), runs: [:])
        await f.api.seed(value)
        var cached = value
        cached.usage?.version = 2
        cached.usage?.total = .init(microcredits: 200_000, calls: 1)
        try await f.cache.save(cached, owner: "owner")
        try await f.cache.saveDraft(AskDraft(text: "Follow up", screenshot: Self.image), key: value.id, owner: "owner")
        await f.model.select(value.id)
        #expect(f.model.modelReference(launcher: false) == "cloud:vision")
        #expect(f.model.draft.includeScreenshot)
        #expect(f.model.draft.screenshot == Self.image)
        #expect(f.model.selected?.usage?.version == 2)
        #expect(f.model.selected?.usage?.total.microcredits == 200_000)
    }

    @Test func retryChecksFreshCloudImageCapabilities() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        let target = try #require(f.model.imageRecoveryTarget)
        await f.api.setCloudModels([.init(id: "vision", name: "Vision", vision: false)])
        f.model.resumeImage(target, reference: "cloud:vision")
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.retryModels.isEmpty)
        #expect(f.model.selected?.run?.status == "failed")
        #expect(f.model.screenshotCapability(launcher: false) == .unsupported)
        #expect(f.model.error != nil)
    }

    @Test func deletingAnotherConversationCannotResurrectItsDraft() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        for id in ["first", "second"] { await f.api.seed(conversation(id)) }
        await f.model.select("first")
        f.model.draft.text = "Unsaved changes"
        f.model.persistDrafts()
        await f.model.select("second")
        f.model.draft.text = "Keep this other draft"
        f.model.launcherDraft.text = "Keep the launcher draft"
        await f.model.delete("first")
        try await Task.sleep(for: .milliseconds(450))
        #expect(try await f.cache.draft(key: "first", owner: "owner") == nil)
        #expect(f.model.selectedId == "second")
        #expect(try await f.cache.draft(key: "second", owner: "owner")?.text == "Keep this other draft")
        #expect(try await f.cache.draft(key: "launcher", owner: "owner")?.text == "Keep the launcher draft")
    }

    @Test func refreshDiscoversImageModelsWithoutSelectingOrResuming() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        var registry = f.model.modelLibrary.registry
        registry.providers.removeAll(where: \.isOllama)
        try f.model.modelLibrary.commit(registry)
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        await f.api.setCloudModels([.init(id: "new-vision", name: "New Vision", vision: true)])
        await f.model.refreshImageModels()
        #expect(f.model.modelLibrary.imageCapability("cloud:new-vision") == .supported)
        #expect(f.model.modelReference(launcher: false) == "cloud:text")
        #expect(await f.api.retryModels.isEmpty)
        await f.api.setFailModels(true)
        await f.model.refreshImageModels()
        #expect(f.model.modelLibrary.catalogError != nil)
        #expect(f.model.modelLibrary.imageCapability("cloud:new-vision") == .supported)
    }

    @Test func failedCatalogOnlyHidesCloudChoicesInTheRecoveryPicker() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let library = f.model.modelLibrary
        var registry = library.registry
        registry.providers.append(.init(id: "fixture", name: "Local", baseURL: "https://example.invalid/v1",
            models: [.init(id: "vision", name: "Vision", reference: "custom:fixture", vision: true),
                     .init(id: "text", name: "Text", reference: "custom:text", vision: false)]))
        try library.commit(registry)
        let originalRegistry = library.registry
        #expect(library.imageRecoveryProviders(loggedIn: true).contains(where: { $0.isCloud }))
        library.catalogError = "Fetch failed"
        let remaining = library.imageRecoveryProviders(loggedIn: true)
        #expect(!remaining.contains(where: { $0.isCloud }))
        #expect(remaining.flatMap(\.models).map(\.reference) == ["custom:fixture"])
        #expect(library.registry == originalRegistry)
        library.catalogError = nil
        #expect(library.imageRecoveryProviders(loggedIn: true).contains(where: { $0.isCloud }))
        #expect(!library.imageRecoveryProviders(loggedIn: false).contains(where: { $0.isCloud }))
    }

    @Test func customModelsDoNotDependOnCloudCatalogAvailability() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        var registry = f.model.modelLibrary.registry
        registry.providers.append(.init(id: "fixture", name: "Fixture", baseURL: "https://example.invalid/v1",
            models: [.init(id: "vision", name: "Vision", reference: "custom:fixture", vision: true)]))
        try f.model.modelLibrary.commit(registry)
        await f.api.setFailModels(true)
        f.model.launcherDraft = AskDraft(text: "Question", includeScreenshot: false, modelRef: "custom:fixture")
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.error == nil)
        #expect(await f.api.sends.count == 1)
    }

    @Test func failedFollowUpDoesNotOfferRecoveryForThePreviousRun() async throws {
        let f = try await fixture()
        defer { f.model.resetSession() }
        let value = conversation()
        await f.api.seed(value)
        await f.model.select(value.id)
        f.model.selectModel("cloud:vision", launcher: false)
        f.model.draft.text = "A new question"
        await f.api.setFailSend(true)
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.imageRecoveryTarget == nil)
        await f.api.setFailSend(false)
        f.model.selectModel("cloud:default", launcher: false)
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.retryModels.isEmpty)
        #expect(await f.api.sends.first?.modelRef == "cloud:vision")
        #expect(await f.api.sends.first?.text == "A new question")
    }

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
