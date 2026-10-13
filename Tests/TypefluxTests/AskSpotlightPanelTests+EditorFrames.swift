import AppKit
import SwiftUI
import Testing
@testable import Typeflux

extension AskSpotlightPanelTests {
    @Test(arguments: InterfaceStyle.allCases)
    func shortQueriesKeepTheNativeComposerAtTheSameTop(_ style: InterfaceStyle) async throws {
        let fixture = try AskTestFixture()
        defer {
            fixture.model.resetSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let view = AskLauncherView(model: fixture.model, onDismiss: {})
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, host in
            let editor = try #require(composerEditor(in: host))
            let scroll = try #require(editor.enclosingScrollView)
            let recorder = ComposerFrames(scroll: scroll, window: window)
            defer { recorder.stop() }
            let top = recorder.screenTop
            for query in ["a", "qq音乐", "1+1", "Help me think", "a"] {
                editor.selectAll(nil)
                editor.insertText(query, replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                #expect(scroll.frame.height >= AskMetrics.composerControlHeight)
                recorder.sample()
            }
            #expect(recorder.tops.allSatisfy { abs($0 - top) < 0.5 },
                    "Native composer moved while short queries changed: \(recorder.tops)")
        }
    }

    private func composerEditor(in view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(composerEditor(in:)).first
    }

    @MainActor private final class ComposerFrames {
        private let scroll: NSScrollView
        private let window: NSWindow
        private var observers: [NSObjectProtocol] = []
        private(set) var tops: [CGFloat] = []

        init(scroll: NSScrollView, window: NSWindow) {
            self.scroll = scroll
            self.window = window
            var ancestor: NSView? = scroll
            while let current = ancestor {
                current.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: current, queue: nil
                ) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } })
                ancestor = current.superview
            }
        }

        var screenTop: CGFloat { window.convertToScreen(scroll.convert(scroll.bounds, to: nil)).maxY }
        func sample() { tops.append(screenTop) }
        func stop() { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
