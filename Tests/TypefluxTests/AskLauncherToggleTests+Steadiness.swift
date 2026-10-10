import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The real launcher panel while its results change with every keystroke:
/// its top edge, the editor and the controls under it must not move.
///
/// These run in the launcher toggle suite: both type into a key launcher panel,
/// so they must take turns rather than run side by side.
extension AskLauncherToggleTests {
    /// Records every frame the panel and the editor's container take, as they
    /// happen, so a frame that lasts only until the next resize is caught too.
    @MainActor fileprivate final class Recorder {
        let panel: NSWindow
        let container: NSView
        private(set) var panelTops: [CGFloat] = []
        private(set) var editorTops: [CGFloat] = []
        private(set) var heights: [CGFloat] = []
        private var observers: [NSObjectProtocol] = []

        init(panel: NSWindow, container: NSView) {
            self.panel = panel
            self.container = container
            var view: NSView? = container
            while let current = view {
                current.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: current, queue: nil
                ) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } })
                view = current.superview
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                })
            }
            // Where the panel stands before anything changes: a first move is a change too.
            sample()
        }

        var editorTop: CGFloat { panel.convertToScreen(container.convert(container.bounds, to: nil)).maxY }

        func sample() {
            panelTops.append(panel.frame.maxY)
            editorTops.append(editorTop)
            heights.append(panel.frame.height)
        }

        func stop() { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    fileprivate func steadyEditor(in view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(steadyEditor(in:)).first
    }

    /// Everything one launcher test creates, closed together whether or not it got as far as typing.
    @MainActor fileprivate struct Owned {
        let fixture: AskTestFixture
        let defaults: UserDefaults
        let suite: String
        let controller: AskConversationWindowController

        func close() {
            controller.dismissLauncher()
            fixture.model.resetSession()
            // After the windows' last writes, so nothing recreates the domain.
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
    }

    /// The launcher as the app shows it, with "a" already typed: the empty
    /// launcher's suggestions are a different layout on purpose.
    @MainActor fileprivate struct Session {
        let owned: Owned
        let panel: NSWindow
        let editor: AskComposerTextView.Editor
        var fixture: AskTestFixture { owned.fixture }

        /// Types each text from an empty field, one character at a time through the real text view,
        /// and returns how many apps were listed after each. With `waitingForResults`, each text's
        /// matches arrive before the next text starts, as for someone reading them; that is still
        /// well within the reserve's settle delay, so it is typing, not a pause.
        @discardableResult
        func type(_ texts: [String], recorder: Recorder, waitingForResults: Bool = false) async throws -> [Int] {
            var shown: [Int] = []
            for text in texts {
                editor.selectAll(nil)
                for char in text {
                    editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await Task.sleep(for: .milliseconds(30))
                }
                if waitingForResults {
                    try await steadily("the results for \"\(text)\" arrive") { searched(text) }
                }
                shown.append(fixture.model.quickSearch.results?.apps.count ?? 0)
                recorder.sample()
            }
            return shown
        }

        /// The launcher has taken `text` in and finished searching for it.
        func searched(_ text: String) -> Bool {
            let search = fixture.model.quickSearch
            return fixture.model.launcherDraft.text == text && search.isCurrent(text: text) && !search.isSearching
        }

        func close() { owned.close() }
    }

    fileprivate func openSteadyLauncher() async throws -> Session {
        _ = NSApplication.shared
        let suite = "ask-steady-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let fixture = try AskTestFixture()
        fixture.model.appIndex = AskTestAppIndex(AskTestAppIndex.sample.entries)
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: fixture.model,
                                                        dockVisibility: DockVisibilityController(app: SteadyActivationPolicy()))
        let owned = Owned(fixture: fixture, defaults: defaults, suite: suite, controller: controller)
        do {
            controller.showLauncher()
            // This controller's own panel: earlier tests can leave other launchers in `NSApp.windows`.
            let panel = try #require(controller.launcherWindow)
            try await steadily("the launcher shows") { panel.isVisible }
            let content = try #require(panel.contentView)
            let editor = try #require(steadyEditor(in: content))
            // The launcher captures its context (source, selection) when it opens, adding
            // a row above the editor when it arrives. That is not typing: let it land first.
            try await steadily("the launcher's context lands") { fixture.capture.calls > 0 && !fixture.model.capturing }
            editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            let session = Session(owned: owned, panel: panel, editor: editor)
            // "a" replaces the suggestions, and the panel moves from their height to the
            // query's. Typing starts once it has arrived, not partway through that move.
            try await steadily("the launcher settles on \"a\"") {
                session.searched("a") && !controller.launcherIsResizing
            }
            return session
        } catch {
            owned.close()
            throw error
        }
    }

    @Test func theEditorAndControlsStayPutWhileResultsComeAndGo() async throws {
        let session = try await openSteadyLauncher()
        defer { session.close() }
        let panel = session.panel
        let fixture = session.fixture
        let container = try #require(session.editor.enclosingScrollView)
        let topAnchor = panel.frame.maxY
        let recorder = Recorder(panel: panel, container: container)
        defer { recorder.stop() }
        let editorAnchor = recorder.editorTop
        try await session.type(["w", "wx", "w", "wec", "t", "tab", "vsc", "qq音乐", "1", "1+1", "1+1*2", "jsq",
                                "how do I", "1234567.89*2", "b"], recorder: recorder)
        #expect(fixture.model.launcherDraft.text == "b")
        #expect(recorder.panelTops.count > 10, "resizes were observed")
        let topDrift = recorder.panelTops.map { abs($0 - topAnchor) }.max() ?? 0
        let editorDrift = recorder.editorTops.map { abs($0 - editorAnchor) }.max() ?? 0
        #expect(topDrift < 0.5, "the panel's top edge moved by \(topDrift)")
        #expect(editorDrift < 0.5, "the editor and its controls moved by \(editorDrift)")
    }

    @Test func theListKeepsItsHeightWhileMatchesComeAndGo() async throws {
        let session = try await openSteadyLauncher()
        defer { session.close() }
        let container = try #require(session.editor.enclosingScrollView)
        let recorder = Recorder(panel: session.panel, container: container)
        defer { recorder.stop() }
        // Three apps for "c", one for "co", three again, none for "e", three again:
        // the panel never shrinks in between.
        let shown = try await session.type(["c", "co", "c", "e", "c"], recorder: recorder, waitingForResults: true)
        #expect(shown[0] > shown[1] && shown[1] > 0 && shown[2] == shown[0] && shown[3] == 0 && shown[4] == shown[0],
                "the matches came and went: \(shown)")
        let heights = recorder.heights
        #expect(heights.count >= 5)
        #expect((heights.max() ?? 0) > (heights.first ?? 0), "the list opened under the editor")
        for (before, after) in zip(heights, heights.dropFirst()) {
            #expect(after >= before - 0.5, "the panel shrank from \(before) to \(after)")
        }
    }
}

/// A condition the launcher did not reach in time.
private struct SteadyTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Waits until `condition` holds, failing the test rather than letting it go on from a state it never reached.
@MainActor private func steadily(_ what: String, timeout: Duration = .seconds(10),
                                 _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw SteadyTimeout(description: "Timed out waiting until \(what)")
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private final class SteadyActivationPolicy: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) { currentActivationPolicy = policy }
}
