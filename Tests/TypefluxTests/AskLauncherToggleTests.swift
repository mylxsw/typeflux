import AppKit
import Testing
@testable import Typeflux

@MainActor
private final class HeldLauncherCapture: AskContextCapturing {
    var pending: [Int: CheckedContinuation<AskCapturedContext, Never>] = [:]
    private(set) var calls = 0
    var requests: [ReadOnlySelectionRequest] = []
    var onMakeRequest: (() -> ReadOnlySelectionRequest)?
    func makeSelectionRequest() -> ReadOnlySelectionRequest { onMakeRequest?() ?? .frontmost() }

    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
        calls += 1
        requests.append(request)
        let id = calls
        return await withCheckedContinuation { pending[id] = $0 }
    }

    func finish(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(returning: .init(selection: "Selection \(id)"))
    }
}

@Suite("Ask launcher toggle", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherToggleTests {
    init() {
        // Launcher chrome initializes shared auth; do not access the user's Keychain.
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
    }

    @MainActor
    private final class InputSourceRecorder: AskLauncherInputSourceSelecting {
        var onSelect: () -> Void = {}
        func selectEnglish() { onSelect() }
    }

    @Test func selectsEnglishAfterFocusOnlyWhenOpeningLauncher() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let suite = "ask-input-source-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let inputSource = InputSourceRecorder()
        var selections = 0
        inputSource.onSelect = {
            selections += 1
            let editor = self.panel()?.firstResponder as? NSTextView
            #expect(editor?.isEditable == true)
        }
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: f.model,
                                                        launcherInputSource: inputSource)
        defer {
            controller.dismissLauncher()
            f.model.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }

        controller.prewarmLauncher()
        #expect(selections == 0)
        controller.showLauncher()
        #expect(selections == 1)

        // Refocusing an open launcher must preserve a manual input-source change.
        panel()?.makeFirstResponder(nil)
        controller.showLauncher()
        #expect(selections == 1)
        controller.dismissLauncher()
        #expect(selections == 1)

        controller.showLauncher()
        #expect(selections == 2)
        controller.showConversation()
        #expect(selections == 2)
        for window in NSApp.windows where window.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-conversations" {
            window.orderOut(nil)
        }
    }

    private func panel() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-launcher" && $0.isVisible
        }
    }

    @Test func launcherAcceptsTextWithoutBecomingAnActivatingOrMainWindow() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }
        f.model.launcherDraft.text = "Unfinished question"

        controller.toggleLauncher()
        try await f.wait { panel() != nil }
        let launcher = try #require(panel())

        // Check both initial presentation and reuse of the same panel.
        for _ in 0..<2 {
            #expect(launcher.styleMask.contains(.nonactivatingPanel))
            #expect(launcher.canBecomeKey)
            #expect(!launcher.canBecomeMain)
            let editor = try #require(launcher.firstResponder as? NSTextView)
            #expect(editor.isEditable)
            #expect(editor.string == "Unfinished question")

            // An already-visible launcher must also restore editor focus.
            launcher.makeFirstResponder(nil)
            controller.showLauncher()
            #expect(launcher.firstResponder === editor)

            controller.toggleLauncher()
            #expect(!launcher.isVisible)
            controller.toggleLauncher()
            try await f.wait { launcher.isVisible }
            #expect(panel() === launcher)
        }
    }

    @Test func repeatedToggleOpensClosesAndPreservesDraft() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }
        f.model.launcherDraft.text = "Unfinished question"

        for _ in 0..<2 {
            controller.toggleLauncher()
            try await f.wait { panel() != nil }
            #expect(panel() != nil)
            controller.toggleLauncher()
            #expect(panel() == nil)
            #expect(f.model.launcherDraft.text == "Unfinished question")
        }
    }

    @Test func toggleCancelsBeforePreparationStartsAndCanImmediatelyReopen() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }
        controller.toggleLauncher()
        controller.toggleLauncher()
        f.model.launcherDraft.text = "Draft"
        controller.toggleLauncher()
        try await f.wait { panel() != nil }
        #expect(f.capture.calls == 0)
        controller.toggleLauncher()
        #expect(panel() == nil)
    }

    @Test func textTypedWhileCapturingKeepsTheLaunchContext() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let capture = HeldLauncherCapture()
        let model = AskConversationModel(api: f.api, cache: f.cache, tools: f.tools, capture: capture,
                                         deviceId: "test", modelLibrary: f.model.modelLibrary, session: { nil })
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: model)
        defer {
            controller.dismissLauncher()
            for id in Array(capture.pending.keys) { capture.finish(id) }
            model.resetSession(); f.model.resetSession()
        }
        let original = ReadOnlySelectionRequest(processID: 42, processName: "Original")
        var source = original
        var madeBeforePanel = false
        capture.onMakeRequest = {
            madeBeforePanel = self.panel() == nil
            return source
        }
        controller.toggleLauncher()
        source = ReadOnlySelectionRequest(processID: 99, processName: "New frontmost")
        #expect(madeBeforePanel)
        // Visible in the same run-loop turn as the hotkey, before any capture.
        #expect(panel() != nil)
        #expect(capture.calls == 0)
        try await f.wait { capture.pending[1] != nil }
        #expect(capture.requests.map(\.id) == [original.id])
        #expect(capture.requests.first?.processID == 42)
        // The user starts typing before the context arrives; both survive.
        model.launcherDraft.text = "Typed early"
        capture.finish(1)
        try await f.wait { model.launcherDraft.selection != nil }
        #expect(model.launcherDraft.text == "Typed early")
        #expect(model.launcherDraft.selection == "Selection 1")
    }

    @Test func cancelledPreparationCannotReopenOrClearNewLaunch() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let capture = HeldLauncherCapture()
        let model = AskConversationModel(api: f.api, cache: f.cache, tools: f.tools, capture: capture,
                                         deviceId: "test", modelLibrary: f.model.modelLibrary, session: { nil })
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: model)
        defer {
            controller.dismissLauncher()
            for id in Array(capture.pending.keys) { capture.finish(id) }
            model.resetSession(); f.model.resetSession()
        }

        // The panel is on screen before its context has been captured.
        controller.toggleLauncher()
        try await f.wait { capture.pending[1] != nil }
        #expect(panel() != nil)
        controller.toggleLauncher()
        #expect(panel() == nil)
        controller.toggleLauncher()
        try await f.wait { capture.pending[2] != nil }
        #expect(panel() != nil)
        capture.finish(1)
        // Let the old task finish while the replacement is still preparing.
        for _ in 0..<10 { await Task.yield() }
        #expect(panel() != nil)
        #expect(model.launcherDraft.selection == nil)
        #expect(model.capturing)
        controller.toggleLauncher()
        #expect(panel() == nil)
        capture.finish(2)
        try await f.wait { !model.capturing }
        // A cancelled launch neither reopens the panel nor applies its context.
        #expect(panel() == nil)
        #expect(model.launcherDraft.selection == nil)

        controller.toggleLauncher()
        try await f.wait { capture.pending[3] != nil }
        #expect(panel() != nil)
        capture.finish(3)
        try await f.wait { model.launcherDraft.selection != nil }
        #expect(model.launcherDraft.selection == "Selection 3")
    }
}
