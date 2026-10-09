import AppKit
import Testing
@testable import Typeflux

@Suite("Ask conversation window sizing", .serialized, .exclusiveUIState)
@MainActor
struct AskConversationWindowSizingTests {
    @Test func supportedNarrowAndShortViewportsRemainAtTheRequestedSize() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let window = try fixture.show()
        // AppKit keeps a titled window inside the visible screen, so the tall case asks for at most
        // what this display can hold (a Screen Sharing display can be much shorter than 880pt).
        let screen = try #require(window.screen ?? NSScreen.main)
        let tallest = floor(window.contentRect(forFrameRect: screen.visibleFrame).height)

        for size in [NSSize(width: 440, height: min(880, tallest)), NSSize(width: 960, height: 320),
                     NSSize(width: 440, height: 320), AskWorkspaceLayout.minimumWindowSize] {
            window.setContentSize(size)
            try await settle(window)
            let content = try #require(window.contentView)
            #expect(abs(content.bounds.width - size.width) < 1)
            #expect(abs(content.bounds.height - size.height) < 1)
            #expect(abs(window.frame.width - size.width) < 1)
            #expect(abs(window.frame.height - size.height) < 1)
        }
    }

    @Test func autoLayoutMaintainsTheMinimumAfterDraftChangesAndReopening() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let window = try fixture.show()
        let minimum = AskWorkspaceLayout.minimumWindowSize

        // NSWindow's minSize getter can report zero under Auto Layout. Exercise
        // the effective resize limit instead of asserting that advisory value.
        for draft in ["", String(repeating: "An unfinished question\n", count: 20)] {
            fixture.conversation.model.draft.text = draft
            try await settle(window)
            for requested in [NSSize(width: 100, height: 100), NSSize(width: 100, height: 500),
                              NSSize(width: 700, height: 100)] {
                window.setContentSize(requested)
                try await settle(window)
                let content = try #require(window.contentView)
                #expect(abs(content.bounds.width - max(requested.width, minimum.width)) < 1)
                #expect(abs(content.bounds.height - max(requested.height, minimum.height)) < 1)
                #expect(fixture.conversation.model.draft.text == draft)
            }
            #expect(!fixture.controller.windowShouldClose(window))
            #expect(!window.isVisible)
            fixture.controller.showConversation()
            try await settle(window)
            window.setContentSize(.init(width: 100, height: 100))
            try await settle(window)
            #expect(window.contentView?.bounds.size == minimum)
            #expect(fixture.conversation.model.draft.text == draft)
        }
    }

    @Test func restoredWindowKeepsItsPositionSizeAndDraftWhenReopened() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let screen = try #require(NSScreen.main).visibleFrame
        let savedFrame = NSRect(x: screen.minX + 80, y: screen.minY + 80, width: 440, height: 320)
        fixture.save(frame: savedFrame)
        let window = try fixture.show()
        try await settle(window)
        #expect(window.frame == savedFrame)

        fixture.conversation.model.draft.text = "Keep this draft while the window is hidden."
        #expect(!fixture.controller.windowShouldClose(window))
        fixture.controller.showConversation()
        try await settle(window)
        #expect(window.frame == savedFrame)
        #expect(fixture.conversation.model.draft.text == "Keep this draft while the window is hidden.")
    }

    @Test func previouslySavedUndersizedFramesAreClampedOnFirstPresentation() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        fixture.save(frame: NSRect(x: 100, y: 100, width: 120, height: 100))
        let window = try fixture.show()
        try await settle(window)
        #expect(window.contentView?.bounds.size == AskWorkspaceLayout.minimumWindowSize)
        let screen = try #require(window.screen).visibleFrame
        #expect(screen.contains(window.frame))
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(60))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private final class WindowFixture {
        let conversation: AskTestFixture
        let controller: AskConversationWindowController
        let frameName: NSWindow.FrameAutosaveName
        private let suite: String
        private let defaults: UserDefaults

        init() throws {
            _ = NSApplication.shared
            suite = "ask-window-sizing-" + UUID().uuidString
            frameName = suite
            defaults = try #require(UserDefaults(suiteName: suite))
            conversation = try AskTestFixture()
            controller = AskConversationWindowController(
                settings: SettingsStore(defaults: defaults), model: conversation.model,
                dockVisibility: DockVisibilityController(app: WindowActivationPolicy()),
                conversationFrameAutosaveName: frameName
            )
        }

        func show() throws -> NSWindow {
            controller.showConversation()
            return try #require(NSApp.windows.first { $0.frameAutosaveName == frameName })
        }

        func save(frame: NSRect) {
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrame(frame, display: false)
            window.saveFrame(usingName: frameName)
            window.close()
        }

        func close() {
            if let window = NSApp.windows.first(where: { $0.frameAutosaveName == frameName }) {
                window.delegate = nil
                window.setFrameAutosaveName("")
                window.orderOut(nil)
                window.close()
            }
            conversation.model.resetSession()
            NSWindow.removeFrame(usingName: frameName)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private final class WindowActivationPolicy: ActivationPolicyControlling {
        var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
        func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
            currentActivationPolicy = policy
        }
    }
}
