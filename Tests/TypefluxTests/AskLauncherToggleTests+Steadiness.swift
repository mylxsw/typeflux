import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The real launcher panel while its results change with every keystroke:
/// its top edge, the editor and the controls under it must not move.
///
/// These run in the launcher toggle suite: both find the visible launcher by
/// its window identifier, so they must take turns rather than run side by side.
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

    /// The launcher as the app shows it, with "a" already typed: the empty
    /// launcher's suggestions are a different layout on purpose.
    @MainActor fileprivate struct Session {
        let fixture: AskTestFixture
        let controller: AskConversationWindowController
        let panel: NSWindow
        let editor: AskComposerTextView.Editor
        let defaults: UserDefaults
        let suite: String

        /// Types each text from an empty field, one character at a time through the real text view.
        func type(_ texts: [String], recorder: Recorder) async throws {
            for text in texts {
                editor.selectAll(nil)
                for char in text {
                    editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await Task.sleep(for: .milliseconds(30))
                }
                recorder.sample()
            }
        }

        func close() {
            controller.dismissLauncher()
            fixture.model.resetSession()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    fileprivate func openSteadyLauncher() async throws -> Session {
        _ = NSApplication.shared
        let fixture = try AskTestFixture()
        fixture.model.appIndex = AskTestAppIndex(AskTestAppIndex.sample.entries)
        let suite = "ask-steady-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: fixture.model,
                                                        dockVisibility: DockVisibilityController(app: SteadyActivationPolicy()))
        controller.showLauncher()
        // Earlier tests leave their (hidden) launchers behind; this one is the visible one.
        func visibleLauncher() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-launcher" && $0.isVisible }
        }
        try await fixture.wait { visibleLauncher() != nil }
        let panel = try #require(visibleLauncher())
        let content = try #require(panel.contentView)
        let editor = try #require(steadyEditor(in: content))
        // The launcher captures its context (source, selection) when it opens, adding
        // a row above the editor when it arrives. That is not typing: let it land first.
        try await fixture.wait { fixture.capture.calls > 0 && !fixture.model.capturing }
        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(300))
        return Session(fixture: fixture, controller: controller, panel: panel, editor: editor, defaults: defaults, suite: suite)
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
        // Five apps for "w", one for "wx", five again: the panel never shrinks in between.
        try await session.type(["w", "wx", "w", "we", "wec"], recorder: recorder)
        let heights = recorder.heights
        #expect(heights.count >= 5)
        for (before, after) in zip(heights, heights.dropFirst()) {
            #expect(after >= before - 0.5, "the panel shrank from \(before) to \(after)")
        }
    }
}

private final class SteadyActivationPolicy: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) { currentActivationPolicy = policy }
}
