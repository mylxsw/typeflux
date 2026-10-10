import AppKit
import Testing
@testable import Typeflux

@MainActor
@Suite("Ask window lifecycle", .serialized, .exclusiveUIState)
struct AskConversationWindowLifecycleTests {
    @Test func conversationAndControlWindowsReuseOwnedContentAndRestoreFocus() async throws {
        try await withController { fixture, controller, policy in
            controller.showConversation()
            await controller.conversationRefreshTask?.value
            let conversation = try #require(controller.conversationWindow)
            #expect(conversation.isVisible)
            #expect(policy.currentActivationPolicy == .regular)
            #expect(conversation.contentView?.isOpaque == false)
            fixture.model.draft.text = "Keep this draft across control mode."
            fixture.model.onControlChanged?(true)
            let control = try #require(controller.controlWindow)
            #expect(control.isVisible)
            #expect(!conversation.isVisible)
            #expect(control.styleMask.contains(.nonactivatingPanel))
            #expect(control.level == .floating)
            #expect(!control.isOpaque)
            #expect(control.canBecomeKey && !control.canBecomeMain)
            fixture.model.onControlChanged?(true)
            #expect(controller.controlWindow === control)
            fixture.model.onControlChanged?(false)
            #expect(!control.isVisible)
            #expect(conversation.isVisible)
            #expect(fixture.model.draft.text == "Keep this draft across control mode.")
            // An inactive callback while already hidden must not raise a dismissed conversation.
            #expect(!controller.windowShouldClose(conversation))
            fixture.model.onControlChanged?(false)
            #expect(!conversation.isVisible)
            #expect(policy.currentActivationPolicy == .accessory)
            controller.showConversation()
            await controller.conversationRefreshTask?.value
            #expect(controller.conversationWindow === conversation)
            #expect(conversation.isVisible)
            controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: conversation))
            controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: "unrelated"))
            #expect(policy.currentActivationPolicy == .accessory)
        }
    }

    @Test func controlStopButtonCancelsItsRunAndReturnsToTheConversation() async throws {
        try await withController { fixture, controller, _ in
            await seed("paused_credits", fixture)
            controller.showConversation()
            await controller.conversationRefreshTask?.value
            let conversation = try #require(controller.conversationWindow)
            fixture.model.controllingConversationId = "lifecycle"
            fixture.model.onControlChanged?(true)
            let control = try #require(controller.controlWindow)
            let content = try #require(control.contentView)
            try await SettingsBehaviorTestSupport.wait {
                SettingsBehaviorTestSupport.contains(L("ask.stopControl"), in: content)
            }
            try SettingsBehaviorTestSupport.button(L("ask.stopControl"), in: content).press()
            try await SettingsBehaviorTestSupport.wait { fixture.model.selected?.run?.status == "cancelled" }
            #expect(fixture.model.controllingConversationId == nil)
            #expect(!control.isVisible)
            #expect(conversation.isVisible)
        }
    }

    @Test func pausedCreditRunClosesWithoutStoppingAndPersistsItsDraft() async throws {
        try await withController { fixture, controller, policy in
            await seed("paused_credits", fixture)
            fixture.model.draft.text = "Continue after buying credits."
            controller.showConversation()
            await controller.conversationRefreshTask?.value
            let window = try #require(controller.conversationWindow)
            #expect(!controller.windowShouldClose(window))
            #expect(!window.isVisible)
            #expect(fixture.model.selected?.run?.status == "paused_credits")
            #expect(policy.currentActivationPolicy == .accessory)
            let deadline = ContinuousClock.now + .seconds(3)
            var saved: AskDraft?
            repeat {
                saved = try await fixture.cache.draft(key: "lifecycle", owner: fixture.sessionState.owner)
                if saved?.text == "Continue after buying credits." { break }
                guard ContinuousClock.now < deadline else { throw DraftSaveTimeout() }
                try await Task.sleep(for: .milliseconds(10))
            } while true
            #expect(saved?.text == "Continue after buying credits.")
        }
    }

    @Test(arguments: [0, 1, 2])
    func runningCloseDialogHonorsContinueStopAndCancel(_ choice: Int) async throws {
        try await withController { fixture, controller, _ in
            await seed("awaiting_approval", fixture)
            controller.showConversation()
            await controller.conversationRefreshTask?.value
            let window = try #require(controller.conversationWindow)
            var handled = false
            controller.confirmRunningClose = { alert in
                #expect(alert.messageText == L("ask.close.running"))
                #expect(alert.buttons.map(\.title) == [
                    L("ask.close.continue"), L("ask.close.stop"), L("ask.close.cancel")
                ])
                handled = true
                return [.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn][choice]
            }
            #expect(!controller.windowShouldClose(window))
            #expect(handled)
            #expect(window.isVisible == (choice == 2))
            if choice == 1 {
                try await SettingsBehaviorTestSupport.wait { fixture.model.selected?.run?.status == "cancelled" }
            } else {
                #expect(fixture.model.selected?.run?.status == "awaiting_approval")
            }
        }
    }

    private func seed(_ status: String, _ fixture: AskTestFixture) async {
        let run = AskRun(id: "lifecycle-run", deviceId: "other-device", status: status, steps: 1,
                         updatedAt: Date(), tools: [], pending: [])
        await fixture.api.seed(.init(id: "lifecycle", title: "Window lifecycle", revision: 1,
                                    updatedAt: Date(), messages: [], run: run))
        await fixture.model.refreshHistory()
        await fixture.model.select("lifecycle")
    }

    private func withController(_ check: (AskTestFixture, AskConversationWindowController,
                                         Policy) async throws -> Void) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try AskTestFixture(
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            )
            let policy = Policy()
            let name = "AskLifecycle-" + UUID().uuidString
            let controller = AskConversationWindowController(
                settings: settings, model: fixture.model, dockVisibility: DockVisibilityController(app: policy),
                conversationFrameAutosaveName: name
            )
            @MainActor func cleanup() async {
                controller.conversationRefreshTask?.cancel()
                await controller.conversationRefreshTask?.value
                controller.dismissLauncher()
                fixture.model.resetSession()
                for window in [controller.conversationWindow, controller.controlWindow].compactMap({ $0 }) {
                    window.delegate = nil
                    window.setFrameAutosaveName("")
                    window.contentView = nil
                    window.orderOut(nil)
                    window.close()
                    #expect(!window.isVisible)
                }
                NSWindow.removeFrame(usingName: name)
                try? FileManager.default.removeItem(at: fixture.root)
            }
            do { try await check(fixture, controller, policy) } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    }

    final class Policy: ActivationPolicyControlling {
        var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
        func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) { currentActivationPolicy = policy }
    }

    private struct DraftSaveTimeout: Error {}
}
