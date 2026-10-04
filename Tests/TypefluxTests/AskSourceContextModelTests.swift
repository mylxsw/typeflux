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

    @Test func explicitRefreshReplacesOnlySourceAndClearsSelectionWhilePreservingIndependentContent() async throws {
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
        #expect(refreshed.selection == nil && refreshed.selectionOff == nil)
        #expect(refreshed.screenshot == before.screenshot)
        #expect(refreshed.memory == before.memory)
        #expect(refreshed.capturedAt == before.capturedAt)
        #expect(refreshed.sourceOff == true && refreshed.memoryOff == true)
        #expect(refreshed.text == before.text && refreshed.attachments == before.attachments)
        #expect(refreshed.references == before.references && refreshed.modelRef == before.modelRef)
        #expect(refreshed.skills == before.skills && refreshed.mcpServers == before.mcpServers)
        #expect(!f.model.launcherContextRestored && !f.model.capturing)
        #expect(f.model.captureWarning == nil)
        #expect(f.capture.selectionRequests == [true, false])
        #expect(f.capture.screenshotRequests == [true, false])
    }

    @Test func refreshKeepsExcludedScreenshotAndMemoryWhenSourceCaptureOmitsThem() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.includeScreenshot = false
        let before = f.model.launcherDraft
        f.capture.context.selection = nil; f.capture.context.selectionStatus = "no-selection-found"
        f.capture.context.memory = nil
        await f.model.refreshLauncherContext()
        #expect(f.capture.screenshotRequests.last == false)
        #expect(!f.model.launcherDraft.includeScreenshot)
        #expect(f.model.launcherDraft.screenshot == before.screenshot)
        #expect(f.model.launcherDraft.selection == nil)
        #expect(f.model.launcherDraft.memory == before.memory)
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
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == L("ask.context.refresh.failed"))
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == false)
        #expect(f.model.captureWarning == nil)
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
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == L("ask.context.refresh.externalApp"))
        #expect(f.model.captureWarning == nil)
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
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == L("ask.context.refresh.externalApp"))
        #expect(f.model.captureWarning == nil)
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
        #expect(f.model.capturing && !f.model.capturingScreenshot)
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

    @Test func sourceRefreshDoesNotDependOnScreenshotAvailability() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.context.screenshot = nil
        f.capture.context.source = "Changed app"
        await f.model.refreshLauncherContext()
        #expect(f.model.launcherDraft.source == "Changed app")
        #expect(f.model.launcherDraft.screenshot == before.screenshot)
        #expect(f.model.launcherDraft.memory == before.memory)
        #expect(!f.model.launcherContextRestored)
        #expect(f.model.captureWarning == nil)
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
        #expect(f.model.launcherDraft.sourceOff == true && f.model.launcherDraft.selectionOff == nil && f.model.launcherDraft.memoryOff == true)
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

    @Test(arguments: AskCapturedContentKind.allCases, [true, false])
    func removalRestorationAndUndoOnlyChangeTheRequestedInclusion(kind: AskCapturedContentKind, launcher: Bool) async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        if !launcher { f.model.draft = f.model.launcherDraft }
        let before = launcher ? f.model.launcherDraft : f.model.draft
        f.model.removeCapturedContent(kind, launcher: launcher)
        let removed = launcher ? f.model.launcherDraft : f.model.draft
        #expect(removed.source == before.source && removed.selection == before.selection && removed.screenshot == before.screenshot)
        #expect(removed.memory == before.memory && removed.text == before.text)
        switch kind {
        case .source:
            #expect(removed.sentSource == nil && removed.sentSelection == before.sentSelection)
            #expect(removed.includeScreenshot == before.includeScreenshot)
        case .selection:
            #expect(removed.sentSelection == nil && removed.sentSource == before.sentSource)
            #expect(removed.includeScreenshot == before.includeScreenshot)
        case .screenshot:
            #expect(!removed.includeScreenshot && removed.sentSource == before.sentSource && removed.sentSelection == before.sentSelection)
        }
        #expect(f.model.capturedContentFeedback(launcher: launcher)?.canUndo == true)
        #expect(f.model.capturedContentFeedback(launcher: !launcher) == nil)
        f.model.restoreCapturedContent(kind, launcher: launcher)
        #expect((launcher ? f.model.launcherDraft : f.model.draft) == before)
        #expect(f.model.capturedContentFeedback(launcher: launcher)?.text == L("ask.context.restored.\(kind.rawValue)"))
        f.model.undoCapturedContent(launcher: launcher)
        #expect((launcher ? f.model.launcherDraft : f.model.draft) == removed)
        #expect(f.model.capturedContentFeedback(launcher: launcher)?.canUndo == false)
        f.model.undoCapturedContent(launcher: launcher)
        #expect((launcher ? f.model.launcherDraft : f.model.draft) == removed)
    }

    @Test(arguments: AskCapturedContentKind.allCases)
    func undoRemovalKeepsNewTextFilesAndOtherChoices(kind: AskCapturedContentKind) async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.model.removeCapturedContent(kind, launcher: true)
        f.model.launcherDraft.text = "Newly typed question"
        f.model.launcherDraft.attachments = [.init(kind: .file, name: "New.txt", text: "New file")]
        f.model.launcherDraft.memoryOff = true
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft.sentSource == before.sentSource)
        #expect(f.model.launcherDraft.sentSelection == before.sentSelection)
        #expect(f.model.launcherDraft.includeScreenshot == before.includeScreenshot)
        #expect(f.model.launcherDraft.text == "Newly typed question")
        #expect(f.model.launcherDraft.attachments?.first?.name == "New.txt")
        #expect(f.model.launcherDraft.memoryOff == true)
    }

    @Test func undoReplacementRestoresSourceAndSelectionWithoutRollingBackEditsOrMemoryPurge() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.selectionOff = true
        let before = f.model.launcherDraft
        f.capture.context.source = "Other app"
        f.capture.context.sourceBundleID = "test.other"
        await f.model.refreshLauncherContext()
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == true)
        f.model.launcherDraft.text = "Typed after replacement"
        f.model.launcherDraft.attachments = [.init(kind: .file, name: "New.txt", text: "New")]
        f.model.clearMemory()
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft.source == before.source && f.model.launcherDraft.sourceBundleID == before.sourceBundleID)
        #expect(f.model.launcherDraft.selection == before.selection && f.model.launcherDraft.selectionOff == true)
        #expect(f.model.launcherContextRestored)
        #expect(f.model.launcherDraft.screenshot == before.screenshot && f.model.launcherDraft.capturedAt == before.capturedAt)
        #expect(f.model.launcherDraft.text == "Typed after replacement" && f.model.launcherDraft.attachments?.first?.name == "New.txt")
        #expect(f.model.launcherDraft.memory == AskMemory())
        await f.model.waitForMemoryPurge()
    }

    @Test(arguments: AskCapturedContentKind.allCases)
    func replacingUnderlyingDataInvalidatesRemovalUndo(kind: AskCapturedContentKind) async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(kind, launcher: true)
        switch kind {
        case .source: f.model.launcherDraft.source = "New source"
        case .selection: f.model.launcherDraft.selection = "Replacement selection"
        case .screenshot: f.model.launcherDraft.screenshot = "New screenshot"
        }
        let changed = f.model.launcherDraft
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == false)
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft == changed)
    }

    @Test func unrelatedOrEmptyContentOperationsDoNotReplaceUndo() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(.source, launcher: true)
        let feedback = f.model.capturedContentFeedback(launcher: true)?.text
        f.model.removeCapturedContent(.source, launcher: true)
        f.model.restoreCapturedContent(.selection, launcher: true)
        f.model.launcherDraft.selection = nil
        f.model.removeCapturedContent(.selection, launcher: true)
        f.model.restoreCapturedContent(.selection, launcher: true)
        f.model.draft = .followUp
        f.model.removeCapturedContent(.screenshot, launcher: false)
        #expect(f.model.capturedContentFeedback(launcher: false) == nil)
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == feedback)
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft.sentSource != nil)
        #expect(f.model.launcherDraft.selection == nil)
    }

    @Test func navigationAndNewDraftPreventCrossDraftUndo() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.draft = f.model.launcherDraft
        f.model.removeCapturedContent(.source, launcher: false)
        f.model.newConversation()
        f.model.draft.source = "Unrelated source"; f.model.draft.sourceOff = true
        let newDraft = f.model.draft
        f.model.undoCapturedContent(launcher: false)
        #expect(f.model.draft == newDraft && f.model.capturedContentFeedback(launcher: false) == nil)
        f.model.restoreCapturedContent(.source, launcher: false)
        await f.model.select("other-conversation")
        let selected = f.model.draft
        f.model.undoCapturedContent(launcher: false)
        #expect(f.model.draft == selected && f.model.capturedContentFeedback(launcher: false) == nil)
    }

    @Test func accountSwitchAndResetInvalidateUndoEvenBeforeTheNextCapture() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(.source, launcher: true)
        f.base.sessionState.owner = "different-owner"
        let draft = f.model.launcherDraft
        #expect(f.model.capturedContentFeedback(launcher: true) == nil)
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft == draft)
        f.model.resetSession()
        #expect(f.model.capturedContentFeedback(launcher: true) == nil)
    }

    @Test func freshCaptureClearsFeedbackAndFailedSourceRefreshReportsAnErrorWithoutUndo() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(.source, launcher: true)
        f.capture.context.source = nil
        await f.model.refreshLauncherContext()
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == false)
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == L("ask.context.refresh.failed"))
        f.model.launcherDraft.text = ""
        await f.model.prepareLauncher()
        #expect(f.model.capturedContentFeedback(launcher: true) == nil)
    }

    @Test func pendingSourceRefreshCannotApplyAfterConversationNavigation() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.model.newConversation()
        f.capture.finish(2, with: .init(source: "Must not apply"))
        await refresh.value
        #expect(f.model.launcherDraft == before && f.model.capturedContentFeedback(launcher: true) == nil)
        #expect(!f.model.capturing)
    }

    @Test func pendingRefreshBlocksCapturedContentMutations() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(.source, launcher: true)
        let before = f.model.launcherDraft
        f.capture.held = true
        let refresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        f.model.restoreCapturedContent(.source, launcher: true)
        f.model.removeCapturedContent(.selection, launcher: true)
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft == before)
        refresh.cancel(); f.capture.finish(2)
        await refresh.value
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == true)
    }

    @Test func failedScreenshotRetakeKeepsExistingImageAndUndo() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(.source, launcher: true)
        let before = f.model.launcherDraft
        f.capture.context.screenshot = nil; f.capture.context.warning = "Capture denied"
        await f.model.refreshScreenshot(launcher: true)
        #expect(f.model.launcherDraft == before)
        #expect(f.model.captureWarning == "Capture denied" && !f.model.capturing)
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == true)
    }

    @Test func cancelledScreenshotRetakeAndChangedOwnerDoNotOverwriteOldImage() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let before = f.model.launcherDraft
        f.capture.held = true
        let cancelled = Task { await f.model.refreshScreenshot(launcher: true) }
        try await f.base.wait { f.capture.pending[2] != nil }
        cancelled.cancel(); f.capture.finish(2, with: .init(screenshot: "Cancelled"))
        await cancelled.value
        #expect(f.model.launcherDraft == before && !f.model.capturing)
        let otherAccount = Task { await f.model.refreshScreenshot(launcher: true) }
        try await f.base.wait { f.capture.pending[3] != nil }
        f.base.sessionState.owner = "other-account"
        f.capture.finish(3, with: .init(screenshot: "Other account"))
        await otherAccount.value
        #expect(f.model.launcherDraft == before && !f.model.capturing)
    }

    @Test func replacementAppNameNeverPresentsTypefluxOrUnknownApplicationAsTheTarget() throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        #expect(f.model.launcherReplacementAppName == "New app")
        f.capture.target = .init(processID: ProcessInfo.processInfo.processIdentifier, processName: "Typeflux")
        #expect(f.model.launcherReplacementAppName == nil)
        f.capture.target = .init(processID: nil, processName: "Missing process")
        #expect(f.model.launcherReplacementAppName == nil)
        f.capture.target = .init(processID: 42, processName: "  ")
        #expect(f.model.launcherReplacementAppName == nil)
    }

    @Test func screenshotToggleWorksBeforeFirstCaptureAndAfterFailure() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.screenshot = nil
        f.model.launcherDraft.includeScreenshot = false
        f.model.restoreCapturedContent(.screenshot, launcher: true)
        #expect(f.model.launcherDraft.includeScreenshot && f.model.launcherDraft.screenshot == nil)
        f.capture.context.screenshot = nil
        await f.model.refreshScreenshot(launcher: true)
        #expect(f.model.launcherDraft.includeScreenshot && f.model.captureWarning != nil)
        f.model.removeCapturedContent(.screenshot, launcher: true)
        #expect(!f.model.launcherDraft.includeScreenshot && f.model.launcherDraft.screenshot == nil)
    }

    @Test func screenshotCanBeRemovedDuringCaptureWithoutReenablingItAtCompletion() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.capture.held = true
        let capture = Task { await f.model.refreshScreenshot(launcher: true) }
        try await f.base.wait { f.capture.pending[2] != nil }
        #expect(f.model.capturing && f.model.capturingScreenshot)
        f.model.removeCapturedContent(.screenshot, launcher: true)
        #expect(!f.model.launcherDraft.includeScreenshot)
        f.capture.finish(2, with: .init(screenshot: "Finished capture"))
        await capture.value
        #expect(!f.model.capturing && !f.model.capturingScreenshot)
        #expect(!f.model.launcherDraft.includeScreenshot && f.model.launcherDraft.screenshot == "Finished capture")
        #expect(f.model.launcherDraft.request(deviceId: "device", tools: []).image == nil)
        f.model.restoreCapturedContent(.screenshot, launcher: true)
        #expect(f.model.launcherDraft.request(deviceId: "device", tools: []).image == "Finished capture")
    }

    @Test func textOnlyModelPreventsRestoringOrUndoingScreenshotInclusion() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.removeCapturedContent(.screenshot, launcher: true)
        f.model.launcherDraft.modelRef = "missing-model"
        #expect(f.model.capturedContentFeedback(launcher: true)?.canUndo == false)
        f.model.undoCapturedContent(launcher: true)
        f.model.restoreCapturedContent(.screenshot, launcher: true)
        #expect(!f.model.launcherDraft.includeScreenshot)
        #expect(f.model.launcherDraft.screenshot != nil)
    }

    @Test func expiredFeedbackKeepsExcludedDataAvailableToAddAgain() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.capturedContentFeedbackDuration = .milliseconds(1)
        f.model.removeCapturedContent(.selection, launcher: true)
        try await f.base.wait { f.model.capturedContentFeedback(launcher: true) == nil }
        #expect(f.model.launcherDraft.sentSelection == nil && f.model.launcherDraft.selection != nil)
        f.model.restoreCapturedContent(.selection, launcher: true)
        #expect(f.model.launcherDraft.sentSelection == "New selection")
    }

    @Test func replacementFeedbackCancelsPriorTimerWithoutAffectingOtherComposer() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.draft = f.model.launcherDraft
        f.model.removeCapturedContent(.selection, launcher: false)
        f.model.removeCapturedContent(.source, launcher: true)
        let priorTimer = try #require(f.model.capturedContentFeedbackTasks[true])
        f.model.removeCapturedContent(.selection, launcher: true)
        await priorTimer.value
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == L("ask.context.removed.selection"))
        #expect(f.model.capturedContentFeedback(launcher: false)?.text == L("ask.context.removed.selection"))
        let launcherTimer = try #require(f.model.capturedContentFeedbackTasks[true])
        let composerTimer = try #require(f.model.capturedContentFeedbackTasks[false])
        f.model.resetSession()
        await launcherTimer.value
        await composerTimer.value
        #expect(f.model.capturedContentFeedbackTasks.isEmpty)
        #expect(f.model.capturedContentFeedback(launcher: true) == nil && f.model.capturedContentFeedback(launcher: false) == nil)
    }

    @Test func successfulSubmissionClearsBothComposersUndo() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.draft = f.model.launcherDraft
        f.model.removeCapturedContent(.selection, launcher: false)
        f.model.removeCapturedContent(.source, launcher: true)
        f.model.submitLauncher()
        try await f.base.wait { f.model.busyIds.isEmpty }
        #expect(f.model.capturedContentFeedback(launcher: true) == nil && f.model.capturedContentFeedback(launcher: false) == nil)
        f.model.launcherDraft = AskDraft(text: "New question", source: "New source", sourceOff: true)
        let newDraft = f.model.launcherDraft
        f.model.undoCapturedContent(launcher: true)
        #expect(f.model.launcherDraft == newDraft)
    }

    @Test func sourceRefreshLeavesIndependentScreenshotFailureUntouched() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.model.launcherDraft.screenshot = nil
        f.model.captureWarning = "Screen permission denied"
        f.capture.context.source = "Replacement app"
        await f.model.refreshLauncherContext()
        #expect(f.model.launcherDraft.source == "Replacement app")
        #expect(f.model.launcherDraft.screenshot == nil)
        #expect(f.model.captureWarning == "Screen permission denied")
        f.capture.context.source = nil
        await f.model.refreshLauncherContext()
        #expect(f.model.captureWarning == "Screen permission denied")
        #expect(f.model.capturedContentFeedback(launcher: true)?.text == L("ask.context.refresh.failed"))
    }

    @Test func screenshotRetakeCannotInterruptPendingSourceReplacement() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        let originalImage = f.model.launcherDraft.screenshot
        f.capture.held = true
        let sourceRefresh = Task { await f.model.refreshLauncherContext() }
        try await f.base.wait { f.capture.pending[2] != nil }
        await f.model.refreshScreenshot(launcher: true)
        #expect(f.capture.requests.count == 2)
        #expect(f.model.capturing && !f.model.capturingScreenshot)
        f.capture.finish(2, with: .init(source: "Replacement source", sourceBundleID: "test.replacement"))
        await sourceRefresh.value
        #expect(f.model.launcherDraft.source == "Replacement source")
        #expect(f.model.launcherDraft.selection == nil)
        #expect(f.model.launcherDraft.screenshot == originalImage)
        #expect(!f.model.capturing && !f.model.launcherContextRestored)
    }

    @Test func screenshotRetakeCannotInvalidateInitialCaptureWithoutScreenshot() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.model.refreshHistory()
        f.model.launcherDraft.includeScreenshot = false
        f.capture.held = true
        let preparation = Task { await f.model.prepareLauncher() }
        try await f.base.wait { f.capture.pending[1] != nil }
        #expect(f.capture.screenshotRequests == [false])
        f.model.restoreCapturedContent(.screenshot, launcher: true)
        await f.model.refreshScreenshot(launcher: true)
        #expect(f.capture.requests.count == 1)
        #expect(f.model.capturing && !f.model.capturingScreenshot)
        f.capture.finish(1, with: .init(selection: "Initial selection", source: "Initial source"))
        await preparation.value
        #expect(f.model.launcherDraft.source == "Initial source")
        #expect(f.model.launcherDraft.selection == "Initial selection")
        #expect(!f.model.capturing)
    }

    @Test func overlappingScreenshotRetakesStillKeepTheNewestResult() async throws {
        let f = try SourceContextFixture()
        defer { f.cleanUp() }
        await f.restore()
        f.capture.held = true
        let first = Task { await f.model.refreshScreenshot(launcher: true) }
        try await f.base.wait { f.capture.pending[2] != nil }
        let second = Task { await f.model.refreshScreenshot(launcher: true) }
        try await f.base.wait { f.capture.pending[3] != nil }
        f.capture.finish(2, with: .init(screenshot: "Stale screenshot"))
        await first.value
        #expect(f.model.capturing && f.model.capturingScreenshot)
        #expect(f.model.launcherDraft.screenshot != "Stale screenshot")
        f.capture.finish(3, with: .init(screenshot: "Latest screenshot"))
        await second.value
        #expect(f.model.launcherDraft.screenshot == "Latest screenshot")
        #expect(!f.model.capturing && !f.model.capturingScreenshot)
    }
}
