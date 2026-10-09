import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Drives the real launcher with key presses: Return copies, ⌘Return asks the
/// AI, Tab keeps calculating and the arrows move. Copies go to a private
/// pasteboard, never the user's clipboard.
@Suite("Ask quick results in the launcher", .serialized, .exclusiveUIState)
@MainActor
struct AskQuickResultsInteractionTests {
    @MainActor final class Launcher {
        let fixture: AskTestFixture
        let window: AskTestVoiceWindow
        let editor: AskComposerTextView.Editor
        var dismissed = 0
        var opened: [URL] = []
        /// Every height the launcher asked its panel for.
        var heights: [CGFloat] = []

        init(text: String, apps: AskTestAppIndex = AskTestAppIndex([]), selection: String? = nil, waitForSearch: Bool = true,
             prepare: (AskConversationModel) -> Void = { _ in }) async throws {
            // Launcher chrome initializes shared auth; keep it away from the user's Keychain.
            let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
            KeychainTokenStore.useInMemoryStoreForTesting = true
            _ = AuthState.shared
            KeychainTokenStore.useInMemoryStoreForTesting = previousStore
            fixture = try AskTestFixture()
            fixture.model.appIndex = apps
            prepare(fixture.model)
            fixture.model.launcherDraft = AskDraft(text: text, includeScreenshot: false, selection: selection)
            window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: AskMetrics.launcherWidth, height: 420),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var dismiss: () -> Void = {}
            var report: (CGFloat) -> Void = { _ in }
            let hosting = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: { dismiss() },
                                                                  onHeightChange: { report($0) }))
            window.contentView = hosting
            window.orderFront(nil)
            var found: AskComposerTextView.Editor?
            for _ in 0 ..< 1000 where found == nil {
                hosting.layoutSubtreeIfNeeded()
                found = Self.editor(in: hosting)
                if found == nil { try await Task.sleep(for: .milliseconds(5)) }
            }
            editor = try #require(found)
            dismiss = { [unowned self] in dismissed += 1 }
            report = { [weak self] in self?.heights.append($0) }
            fixture.model.openApplication = { [unowned self] url in opened.append(url) }
            try await Task.sleep(for: .milliseconds(100))
            if waitForSearch {
                try await AskQuickSearchSessionTests.wait { !fixture.model.quickSearch.isSearching }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        private static func editor(in view: NSView) -> AskComposerTextView.Editor? {
            (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(editor(in:)).first
        }

        func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) async throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "",
                                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
            editor.keyDown(with: event)
            try await Task.sleep(for: .milliseconds(50))
        }

        /// Waits for the question to reach the stubbed service.
        func sentCount() async throws -> Int {
            for _ in 0 ..< 500 {
                if await !fixture.api.sends.isEmpty { break }
                try await Task.sleep(for: .milliseconds(4))
            }
            return await fixture.api.sends.count
        }

        func close() {
            fixture.model.resetSession()
            window.close()
        }
    }

    static let returnKey: UInt16 = 36, tab: UInt16 = 48, escape: UInt16 = 53, down: UInt16 = 125, up: UInt16 = 126

    func withPasteboard(_ body: (NSPasteboard) async throws -> Void) async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ask.quick.interaction.\(UUID().uuidString)"))
        let previous = AskQuickResults.pasteboard
        let previousLanguage = AppLocalization.shared.language
        AskQuickResults.pasteboard = pasteboard
        AppLocalization.shared.setLanguage(.english)
        defer {
            AskQuickResults.pasteboard = previous
            AppLocalization.shared.setLanguage(previousLanguage)
            pasteboard.releaseGlobally()
        }
        try await body(pasteboard)
    }

    @Test func returnCopiesTheResultAndClosesTheLauncher() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1234567.89*2")
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "2469135.78")
            #expect(launcher.dismissed == 1)
            #expect(launcher.fixture.model.launcherDraft.text.isEmpty, "the expression is not restored next time")
            #expect(await launcher.fixture.api.sends.isEmpty, "nothing goes to the AI")
        }
    }

    @Test func arrowsChooseAnotherSpelling() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1234567.89*2")
            defer { launcher.close() }
            try await launcher.press(Self.down)
            try await launcher.press(Self.down)
            try await launcher.press(Self.up)
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "2,469,135.78")
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func tabWritesTheResultBackToKeepCalculating() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1+1")
            defer { launcher.close() }
            try await launcher.press(Self.tab)
            #expect(launcher.fixture.model.launcherDraft.text == "2")
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(launcher.dismissed == 0)
        }
    }

    @Test func commandReturnAsksTheAIInstead() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1+1")
            defer { launcher.close() }
            try await launcher.press(Self.returnKey, .command)
            #expect(try await launcher.sentCount() == 1)
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func returnOnAFailedCalculationAsksTheAI() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1/0")
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func escapeStillCloses() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "1+1")
            defer { launcher.close() }
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 1)
            #expect(launcher.fixture.model.launcherDraft.text == "1+1", "closing keeps the draft")
        }
    }

    @Test func turnedOffTheLauncherSendsArithmeticToTheAI() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "")
            defer { launcher.close() }
            launcher.fixture.model.modelLibrary.settings.askQuickCalculatorEnabled = false
            launcher.fixture.model.launcherDraft.text = "1+1"
            try await Task.sleep(for: .milliseconds(100))
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    // MARK: - Applications

    @Test func returnOpensAClearlyNamedApplication() async throws {
        try await withPasteboard { pasteboard in
            let apps = AskTestAppIndex(AskTestAppIndex.sample.entries)
            let launcher = try await Launcher(text: "wx", apps: apps)
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(launcher.opened == [URL(fileURLWithPath: "/Applications/微信.app")])
            #expect(apps.launched == ["com.tencent.xinWeChat"])
            #expect(launcher.dismissed == 1)
            #expect(launcher.fixture.model.launcherDraft.text.isEmpty)
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func aQuestionStillGoesToTheAIWithAppsBelow() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "wechat?", apps: AskTestAppIndex(AskTestAppIndex.sample.entries))
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            #expect(launcher.opened.isEmpty)
        }
    }

    @Test func arrowsReachAnApplicationBelowAskAI() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "wechat?", apps: AskTestAppIndex(AskTestAppIndex.sample.entries))
            defer { launcher.close() }
            try await launcher.press(Self.down)
            try await launcher.press(Self.tab)
            #expect(launcher.fixture.model.launcherDraft.text == "wechat?", "Tab only writes back calculations")
            try await launcher.press(Self.returnKey)
            #expect(launcher.opened.count == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func commandReturnAsksTheAIOverAnApplication() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "wx", apps: AskTestAppIndex(AskTestAppIndex.sample.entries))
            defer { launcher.close() }
            try await launcher.press(Self.returnKey, .command)
            #expect(try await launcher.sentCount() == 1)
            #expect(launcher.opened.isEmpty)
        }
    }

    @Test func turnedOffAppSearchLeavesNamesToTheAI() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "", apps: AskTestAppIndex(AskTestAppIndex.sample.entries))
            defer { launcher.close() }
            launcher.fixture.model.modelLibrary.settings.askQuickAppSearchEnabled = false
            launcher.fixture.model.launcherDraft.text = "wx"
            try await Task.sleep(for: .milliseconds(100))
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
            #expect(launcher.opened.isEmpty)
        }
    }

    @Test func refreshingAppsFollowsTheSetting() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let apps = AskTestAppIndex([])
        fixture.model.appIndex = apps
        fixture.model.refreshQuickApps()
        #expect(apps.refreshes == 1)
        fixture.model.modelLibrary.settings.askQuickAppSearchEnabled = false
        fixture.model.refreshQuickApps()
        #expect(apps.refreshes == 1)
    }
}
