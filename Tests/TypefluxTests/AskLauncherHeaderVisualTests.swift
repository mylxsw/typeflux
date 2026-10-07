import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Typeflux

/// Opt-in renders of the launcher's header, bottom bar and recording states with
/// the production views (set TYPEFLUX_ASK_SNAPSHOTS). They never touch real
/// accounts, screens or microphones.
@Suite("Ask launcher header snapshots", .serialized)
@MainActor
struct AskLauncherHeaderVisualTests {
    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL,
                                 prepare: (NSWindow) async throws -> Void = { _ in }) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        try await prepare(window)
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 4000)
    }

    private func captured(_ fixture: AskTestFixture, text: String = "") {
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 320, height: 200), type: .png)
        var draft = AskDraft(text: text)
        draft.source = "Google Chrome — Issues | Multica - Google Chrome"
        draft.sourceBundleID = "com.google.Chrome"
        draft.screenshot = "data:image/png;base64," + png.base64EncodedString()
        draft.capturedAt = Date()
        fixture.model.launcherDraft = draft
    }

    private func editor(in window: NSWindow) throws -> AskComposerTextView.Editor {
        func find(_ view: NSView) -> AskComposerTextView.Editor? {
            if let editor = view as? AskComposerTextView.Editor { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(window.contentView!))
    }

    /// Starts a recording and plays levels and words into it.
    private func record(_ fixture: AskTestFixture, in window: NSWindow, words: String?, stop: Bool) throws {
        let recorder = AskLiveTestRecorder()
        recorder.holdTranscript = true
        fixture.model.voiceInput.recorder = recorder
        let editor = try editor(in: window)
        window.makeFirstResponder(editor)
        #expect(fixture.model.voiceInput.begin(in: editor))
        var clock: TimeInterval = 0
        fixture.model.voiceInput.live.now = { clock }
        for index in 0..<AskVoiceLive.barCount {
            clock += 1
            let wave = abs(sin(Double(index) * 0.55) * cos(Double(index) * 0.21 + 1))
            recorder.level?(Float(index > 4 && index < 28 ? wave : wave * 0.35))
        }
        if let words {
            recorder.transcript?("帮我把这段话翻译成英文，", true)
            recorder.transcript?(words, false)
        }
        if stop { fixture.model.voiceInput.stop() }
    }

    @Test func renderLauncherHeaderStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        func system(_ file: String, _ name: String, _ english: String) -> AskAppEntry {
            AskAppEntry(name: name, url: URL(fileURLWithPath: "/System/Applications/\(file).app"),
                        bundleID: "com.apple." + file.lowercased(), names: [english])
        }
        let apps = AskTestAppIndex([system("Calculator", "计算器", "Calculator"), system("Calendar", "日历", "Calendar"),
                                    system("Weather", "天气", "Weather")])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // Idle: a clear editor; suggestions; context switches in the bottom bar.
            do {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                captured(fixture)
                try await render(launcher(fixture), size: NSSize(width: AskMetrics.launcherWidth, height: 270),
                                 appearance: appearance, file: root.appendingPathComponent("header-idle-\(name).png"))
            }
            // Typing: the full editor width; quick results with headings.
            for (item, text, height) in [("apps", "cal", CGFloat(300)), ("calculator", "1+1", 350)] {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                fixture.model.appIndex = apps
                captured(fixture, text: text)
                try await render(launcher(fixture), size: NSSize(width: AskMetrics.launcherWidth, height: height),
                                 appearance: appearance,
                                 file: root.appendingPathComponent("header-\(item)-\(name).png"))
            }
            // Recording: live words over the editor, the voice panel in the results' place.
            for (item, words, stop) in [("listening", "帮我把这段话翻译成英文，语气正式一点", false),
                                        ("transcribing", nil, true)] {
                let fixture = try AskTestFixture()
                defer { fixture.model.voiceInput.cancel(); fixture.model.resetSession() }
                captured(fixture)
                try await render(launcher(fixture), size: NSSize(width: AskMetrics.launcherWidth, height: 270),
                                 appearance: appearance,
                                 file: root.appendingPathComponent("header-\(item)-\(name).png")) { window in
                    try record(fixture, in: window, words: words, stop: stop)
                }
            }
            // The conversation window's composer follows the same icon rule.
            do {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                fixture.model.draft = AskDraft(text: "继续追问")
                let composer = AskComposer(model: fixture.model, availableWidth: 720, launcher: false)
                    .padding(20)
                    .environment(\.askGlassMaterialOverride, .opaque)
                try await render(composer, size: NSSize(width: 760, height: 180), appearance: appearance,
                                 file: root.appendingPathComponent("header-workspace-composer-\(name).png"))
            }
            // The context panel the footer settings button opens.
            do {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                captured(fixture)
                fixture.model.launcherDraft.selection = "first line\nsecond line"
                let draft = Binding(get: { fixture.model.launcherDraft }, set: { fixture.model.launcherDraft = $0 })
                let thumbnail = AskAttachmentStrip.thumbnail(dataURL: fixture.model.launcherDraft.screenshot,
                                                             capturedAt: fixture.model.launcherDraft.capturedAt)
                let panel = AskLauncherContextPanel(draft: draft, thumbnail: thumbnail, screenshotState: .attached,
                                                    restored: true, capturing: false, screenshotCapturing: false,
                                                    setIncluded: { _, _ in }, toggleScreenshot: {}, fixScreenshot: nil,
                                                    recapture: {}, refresh: {},
                                                    refreshTitle: L("ask.context.panel.useApp", "Google Chrome"))
                    .background(AskTheme.composerSurface)
                try await render(panel, size: NSSize(width: AskLauncherContextPanel.width, height: 400),
                                 appearance: appearance,
                                 file: root.appendingPathComponent("header-context-panel-\(name).png"))
            }
        }
    }

    private func launcher(_ fixture: AskTestFixture) -> some View {
        AskLauncherView(model: fixture.model, onDismiss: {})
            .environment(\.askGlassMaterialOverride, .opaque)
    }
}
