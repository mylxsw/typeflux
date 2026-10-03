import Foundation
import Testing
@testable import Typeflux

@MainActor
private final class SourceContextCapture: AskContextCapturing {
    var target = ReadOnlySelectionRequest(processID: 42, processName: "New app", bundleIdentifier: "test.new")
    var context = AskCapturedContext(selection: "New selection", selectionStatus: "accessibility-context", source: "New app — New window",
                                     sourceBundleID: "test.new", screenshot: "new-image",
                                     capturedAt: Date(timeIntervalSince1970: 200), memory: AskMemory(global: "New memory"))
    var held = false
    private(set) var requests: [ReadOnlySelectionRequest] = []
    private(set) var screenshotRequests: [Bool] = []
    private(set) var selectionRequests: [Bool] = []
    private(set) var pending: [Int: CheckedContinuation<AskCapturedContext, Never>] = [:]

    func makeSelectionRequest() -> ReadOnlySelectionRequest { target }

    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
        requests.append(request); screenshotRequests.append(includeScreenshot); selectionRequests.append(includeSelection)
        let id = requests.count
        if held { return await withCheckedContinuation { pending[id] = $0 } }
        var result = context
        if !includeScreenshot { result.screenshot = nil }
        return result
    }

    func finish(_ id: Int, with context: AskCapturedContext? = nil) {
        pending.removeValue(forKey: id)?.resume(returning: context ?? self.context)
    }
}

@MainActor
private struct SourceContextFixture {
    let base: AskTestFixture
    let capture = SourceContextCapture()
    let model: AskConversationModel

    init() throws {
        base = try AskTestFixture()
        let state = base.sessionState
        model = AskConversationModel(api: base.api, cache: base.cache, tools: base.tools, capture: capture,
                                     deviceId: "device", modelLibrary: base.model.modelLibrary,
                                     defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                     session: { (state.owner, "token") })
    }

    func restore() async {
        await model.prepareLauncher()
        model.launcherDraft.text = "Unfinished question"
        await model.prepareLauncher()
    }

    func cleanUp() {
        for id in Array(capture.pending.keys) { capture.finish(id) }
        model.resetSession(); base.model.resetSession()
    }
}

@Suite("Ask source context model")
@MainActor
struct AskSourceContextModelTests {
    @Test func legacyDraftIncludesSourceAndNewDraftRoundTripsExclusion() throws {
        let legacy = Data(#"{"text":"Question","include_screenshot":true,"source":"Safari — Title","source_bundle_id":"com.apple.Safari"}"#.utf8)
        var draft = try AskCoding.decoder().decode(AskDraft.self, from: legacy)
        #expect(draft.sourceOff == nil)
        #expect(draft.sentSource == "Safari — Title")
        draft.sourceOff = true
        let restored = try AskCoding.decoder().decode(AskDraft.self, from: AskCoding.encoder().encode(draft))
        #expect(restored.sourceOff == true)
        #expect(restored.source == "Safari — Title")
        #expect(restored.sourceBundleID == "com.apple.Safari")
        #expect(restored.sentSource == nil)
        draft.sourceOff = false
        #expect(draft.sentSource == draft.source)
    }

    @Test func removingSourceOnlyOmitsSourceFromSerializedSendAndSteer() throws {
        var draft = AskDraft(text: "Question", screenshot: "image", selection: "Selected words", source: "Source")
        draft.sourceBundleID = "test.source"; draft.sourceOff = true
        draft.memory = AskMemory(global: "Memory")
        let request = draft.request(deviceId: "device", tools: [])
        let json = try #require(JSONSerialization.jsonObject(with: AskCoding.encoder().encode(request)) as? [String: Any])
        #expect(json["source"] == nil)
        #expect(json["source_off"] == nil && json["source_bundle_id"] == nil)
        #expect(request.selection == "Selected words")
        #expect(request.image == "image")
        #expect(draft.memory?.global == "Memory")
        #expect(AskSteerRequest(runId: "run", message: request).source == nil)
        draft.sourceOff = nil
        #expect(draft.request(deviceId: "device", tools: []).source == "Source")
    }

    @Test func excludedOversizedSourceDoesNotBlockSubmissionOrRemoveOtherContext() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.source = String(repeating: "s", count: 1001)
        f.model.launcherDraft.sourceOff = true
        let before = f.model.launcherDraft
        f.model.submitLauncher()
        try await f.base.wait { f.model.busyIds.isEmpty }
        let sent = try #require(await f.base.api.sends.first)
        #expect(sent.source == nil)
        #expect(sent.selection == before.selection)
        #expect(sent.image == before.screenshot)
        #expect(sent.memory == before.memory)
        #expect(!f.model.launcherContextRestored)
        #expect(f.model.error == nil)
    }

    @Test func reopeningTypedDraftPreservesContextUntilFreshCaptureOrReset() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.context.source = "Changed app"
        await f.model.prepareLauncher()
        #expect(f.capture.requests.count == 1)
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored)
        f.model.launcherDraft.text = ""
        f.model.launcherDraft.sourceOff = true
        await f.model.prepareLauncher()
        #expect(f.model.launcherDraft.source == "Changed app")
        #expect(f.model.launcherDraft.sourceOff == nil)
        #expect(!f.model.launcherContextRestored)
        f.model.launcherDraft.text = "Question"
        await f.model.prepareLauncher()
        f.model.resetSession()
        #expect(!f.model.launcherContextRestored)
    }

    @Test func restoringCachedDraftKeepsSourceAndExclusionWithoutRecapture() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        var saved = AskDraft(text: "Saved question", screenshot: "saved-image", selection: "Saved selection", source: "Saved app")
        saved.sourceOff = true; saved.sourceBundleID = "test.saved"
        try await f.base.cache.saveDraft(saved, key: "launcher", owner: "owner")
        await f.model.prepareLauncher()
        #expect(f.model.launcherDraft == saved)
        #expect(f.model.launcherContextRestored)
        #expect(f.capture.requests.isEmpty)
    }

    @Test func explicitRefreshReplacesContextAndPreservesDraftContentAndChoices() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.sourceOff = true
        f.model.launcherDraft.selectionOff = true
        f.model.launcherDraft.memoryOff = true
        f.model.launcherDraft.modelRef = "cloud:default"
        f.model.launcherDraft.attachments = [.init(kind: .file, name: "Notes.txt", text: "My notes")]
        f.model.launcherDraft.references = [.init(messageId: "m", text: "Passage", question: "Explain")]
        f.model.launcherDraft.skills = ["research"]
        f.model.launcherDraft.mcpServers = ["files"]
        let before = f.model.launcherDraft
        f.capture.context = .init(selection: "Refreshed selection", source: "Refreshed app — Window",
                                  sourceBundleID: "test.refreshed", screenshot: "refreshed-image",
                                  capturedAt: Date(timeIntervalSince1970: 300), memory: AskMemory(global: "Refreshed memory"))
        await f.model.refreshLauncherContext()
        let refreshed = f.model.launcherDraft
        #expect(refreshed.source == f.capture.context.source)
        #expect(refreshed.sourceBundleID == "test.refreshed")
        #expect(refreshed.selection == "Refreshed selection")
        #expect(refreshed.screenshot == "refreshed-image")
        #expect(refreshed.memory?.global == "Refreshed memory")
        #expect(refreshed.capturedAt == Date(timeIntervalSince1970: 300))
        #expect(refreshed.sourceOff == true && refreshed.selectionOff == true && refreshed.memoryOff == true)
        #expect(refreshed.text == before.text && refreshed.attachments == before.attachments)
        #expect(refreshed.references == before.references && refreshed.modelRef == before.modelRef)
        #expect(refreshed.skills == before.skills && refreshed.mcpServers == before.mcpServers)
        #expect(!f.model.launcherContextRestored && !f.model.capturing)
        #expect(f.model.captureWarning == nil)
        #expect(f.capture.selectionRequests == [true, true])
    }

    @Test func refreshRespectsDisabledScreenshotAndClearsAbsentSelectionAndMemory() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.includeScreenshot = false
        f.capture.context.selection = nil; f.capture.context.selectionStatus = "no-selection-found"
        f.capture.context.memory = nil
        await f.model.refreshLauncherContext()
        #expect(f.capture.screenshotRequests.last == false)
        #expect(!f.model.launcherDraft.includeScreenshot)
        #expect(f.model.launcherDraft.screenshot == nil)
        #expect(f.model.launcherDraft.selection == nil)
        #expect(f.model.launcherDraft.memory == AskMemory())
        #expect(!f.model.launcherContextRestored)
    }

    @Test(arguments: ["target-changed", "source-unavailable", "capture-cancelled", "permission-missing",
                      "capture-busy", "pinned-source-unavailable", "search-incomplete", "ax-cannot-complete",
                      "ax-error", "selection-unreadable", "invalid-ax-value", "ax-unsupported", "ax-no-value",
                      "selection-unavailable"])
    func discardedRefreshPreservesOriginalContextAndRestoredMarker(status: String) async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.context = .init(selectionStatus: status, source: "Rejected app", sourceBundleID: "test.rejected",
                                  screenshot: "rejected-image", memory: AskMemory(global: "Rejected memory"))
        await f.model.refreshLauncherContext()
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored)
        #expect(f.model.captureWarning == L("ask.context.refresh.failed"))
        #expect(!f.model.capturing)
    }

    @Test func sourceAppMustBeExternalToRefreshContext() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.target = .init(processID: ProcessInfo.processInfo.processIdentifier, processName: "Typeflux")
        await f.model.refreshLauncherContext()
        #expect(f.capture.requests.count == 1)
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored)
        #expect(f.model.captureWarning == L("ask.context.refresh.externalApp"))
        #expect(!f.model.capturing)
    }

    @Test func selfAppRefreshAlsoInvalidatesAnEarlierPendingRefresh() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.capture.target = .init(processID: ProcessInfo.processInfo.processIdentifier, processName: "Typeflux")
        await f.model.refreshLauncherContext()
        f.capture.finish(2, with: .init(source: "Stale source", screenshot: "stale-image"))
        await refresh.value
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored)
        #expect(f.model.captureWarning == L("ask.context.refresh.externalApp"))
        #expect(!f.model.capturing)
    }

    @Test func submissionsCannotClearLauncherDraftWhileRefreshIsPending() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.draft.text = "Another question"
        let before = f.model.launcherDraft
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        #expect(!f.model.canSendLauncher && !f.model.canSend)
        f.model.submitLauncher()
        f.model.submitDraft()
        #expect(f.model.launcherDraft == before)
        #expect(f.model.draft.text == "Another question")
        #expect(f.model.selected == nil)
        #expect(await f.base.api.sends.isEmpty)
        f.capture.finish(2)
        await refresh.value
        #expect(f.model.canSendLauncher)
    }

    @Test func failedScreenshotRefreshPreservesAllOldContextAndReportsFailure() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.context.screenshot = nil
        f.capture.context.warning = "Screen capture denied"
        await f.model.refreshLauncherContext()
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored)
        #expect(f.model.captureWarning == "Screen capture denied")
    }

    @Test func refreshPinsTargetAndPreservesEditsMadeDuringCapture() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let pinned = f.capture.target
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.capture.target = .init(processID: 99, processName: "Another app")
        f.model.launcherDraft.text = "Edited while refreshing"
        f.model.launcherDraft.sourceOff = true; f.model.launcherDraft.selectionOff = true; f.model.launcherDraft.memoryOff = true
        f.model.launcherDraft.includeScreenshot = false
        f.model.launcherDraft.attachments = [.init(kind: .file, name: "Added.txt", text: "Added during capture")]
        f.capture.finish(2)
        await refresh.value
        #expect(f.capture.requests.last?.id == pinned.id)
        #expect(f.capture.requests.last?.processID == 42)
        #expect(f.model.launcherDraft.text == "Edited while refreshing")
        #expect(f.model.launcherDraft.attachments?.first?.name == "Added.txt")
        #expect(f.model.launcherDraft.sourceOff == true && f.model.launcherDraft.selectionOff == true && f.model.launcherDraft.memoryOff == true)
        #expect(!f.model.launcherDraft.includeScreenshot)
    }

    @Test func olderRefreshCannotOverrideNewerResultOrClearItsBusyState() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.capture.held = true
        let first = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        let second = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[3] != nil }
        f.capture.finish(2, with: .init(source: "Stale", screenshot: "stale"))
        await first.value
        #expect(f.model.capturing)
        #expect(f.model.launcherDraft.source != "Stale")
        f.capture.finish(3, with: .init(source: "Newest", screenshot: "newest"))
        await second.value
        #expect(f.model.launcherDraft.source == "Newest")
        #expect(!f.model.capturing && !f.model.launcherContextRestored)
    }

    @Test func cancelledRefreshDoesNotChangeDraftOrMarkItRefreshed() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        refresh.cancel(); f.capture.finish(2)
        await refresh.value
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored)
        #expect(f.model.captureWarning == nil && !f.model.capturing)
        let cancelledBeforeStart = Task { await f.model.refreshLauncherContext() }
        cancelledBeforeStart.cancel()
        await cancelledBeforeStart.value
        #expect(f.capture.requests.count == 2)
    }

    @Test func sessionResetDuringRefreshCannotRestoreDiscardedContext() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.model.resetSession()
        let reset = f.model.launcherDraft
        f.capture.finish(2)
        await refresh.value
        #expect(f.model.launcherDraft == reset)
        #expect(!f.model.launcherContextRestored && !f.model.capturing)
    }

    @Test func ownerChangeDuringRefreshDoesNotApplyPreviousOwnersCapture() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.base.sessionState.owner = "other-owner"
        f.capture.finish(2, with: .init(source: "Must not apply", screenshot: "new"))
        await refresh.value
        #expect(f.model.launcherDraft == before)
        #expect(f.model.launcherContextRestored && !f.model.capturing)
    }

    @Test func memoryClearedDuringRefreshCannotBeReintroduced() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.model.clearMemory()
        f.capture.finish(2)
        await refresh.value
        #expect(f.model.launcherDraft.memory == AskMemory())
        #expect(!f.model.launcherContextRestored)
        await f.model.waitForMemoryPurge()
    }
}
