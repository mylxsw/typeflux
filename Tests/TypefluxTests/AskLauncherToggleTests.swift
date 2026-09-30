import AppKit
import Testing
@testable import Typeflux

@MainActor
private final class HeldLauncherCapture: AskContextCapturing {
    var pending: [Int: CheckedContinuation<AskCapturedContext, Never>] = [:]
    private(set) var calls = 0

    func capture(includeScreenshot: Bool) async -> AskCapturedContext {
        calls += 1
        let id = calls
        return await withCheckedContinuation { pending[id] = $0 }
    }

    func finish(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(returning: .init(selection: "Selection \(id)"))
    }
}

@Suite("Ask launcher toggle", .serialized)
@MainActor
struct AskLauncherToggleTests {
    private func panel() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-launcher" && $0.isVisible
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

        controller.toggleLauncher()
        try await f.wait { capture.pending[1] != nil }
        controller.toggleLauncher()
        controller.toggleLauncher()
        try await f.wait { capture.pending[2] != nil }
        capture.finish(1)
        // Let the old task finish while the replacement is still preparing.
        for _ in 0..<10 { await Task.yield() }
        #expect(panel() == nil)
        #expect(model.launcherDraft.selection == nil)
        #expect(model.capturing)
        controller.toggleLauncher()
        capture.finish(2)
        try await f.wait { !model.capturing }
        #expect(panel() == nil)
        #expect(model.launcherDraft.selection == nil)

        controller.toggleLauncher()
        try await f.wait { capture.pending[3] != nil }
        capture.finish(3)
        try await f.wait { panel() != nil }
        #expect(model.launcherDraft.selection == "Selection 3")
    }
}
