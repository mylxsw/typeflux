import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask plugin views")
struct AskPluginViewTests {
    private let plan = AskPluginPlan(mode: .onSubmit, title: "Translate", meta: [AskPluginMeta(text: "English")])
    private func output(_ body: String = "Hola", note: String? = nil) -> AskPluginOutput {
        AskPluginOutput(body: body, original: "Hello", meta: [], source: "On this Mac", note: note, actions: [
            AskPluginAction(kind: .copy(body), title: "Copy", symbol: "doc", shortcut: .enter),
            AskPluginAction(kind: .writeBack(body), title: "Replace", symbol: "arrow", shortcut: .optionEnter)
        ])
    }

    private func display(_ phase: AskPluginSession.Phase, hint: AskKeyword? = nil, previous: AskPluginOutput? = nil,
                         comparing: Bool = false, highlighted: Int = 0) -> AskPluginDisplay {
        AskPluginDisplay(hint: hint, title: "Translate", symbol: "translate", phase: phase, previous: previous,
                         comparing: comparing, highlighted: highlighted)
    }

    @Test func heightsFollowWhatIsShown() {
        let row = AskPluginResultsView.height(for: display(.waiting))
        #expect(row == AskPluginResultsView.height(for: display(.ready(plan))))
        let short = AskPluginResultsView.height(for: display(.done(plan, output())))
        let long = AskPluginResultsView.height(for: display(.done(plan, output(String(repeating: "Long text ", count: 60)))))
        #expect(short > row && long > short)
        let huge = AskPluginResultsView.height(for: display(.done(plan, output(String(repeating: "Line\n", count: 80)))))
        #expect(huge - short <= AskPluginResultsView.maximumBodyHeight, "long results scroll inside the card")
        #expect(AskPluginResultsView.height(for: display(.done(plan, output()), comparing: true)) > short)
        #expect(AskPluginResultsView.height(for: display(.done(plan, output(note: "AI")))) > short)
        #expect(AskPluginResultsView.height(for: display(.running(plan))) > row, "a skeleton while the first result comes")
        #expect(AskPluginResultsView.height(for: display(.running(plan), previous: output())) == short)
        let failed = AskPluginResultsView.height(for: display(.failed(plan, AskPluginFailure(message: "Offline"))))
        let final = AskPluginResultsView.height(for: display(.failed(plan, AskPluginFailure(message: "Offline", retry: false))))
        #expect(failed > final)
        let hint = AskPluginResultsView.height(for: display(.waiting, hint: AskTranslatePlugin.keywords[0]))
        #expect(hint < row)
        #expect(AskPluginResultsView.textWidth > 500)
    }

    @Test func theHintSaysWhatTheKeysDo() {
        #expect(AskPluginResultsView.hint(for: display(.waiting, hint: AskTranslatePlugin.keywords[0])) == L("ask.plugin.hint.keyword"))
        #expect(AskPluginResultsView.hint(for: display(.ready(plan), highlighted: 1)) == L("ask.launcher.hint"))
        #expect(AskPluginResultsView.hint(for: display(.waiting)) == L("ask.plugin.hint.waiting"))
        #expect(AskPluginResultsView.hint(for: display(.ready(plan))) == L("ask.plugin.hint.ready"))
        #expect(AskPluginResultsView.hint(for: display(.running(plan))) == L("ask.plugin.hint.running"))
        #expect(AskPluginResultsView.hint(for: display(.done(plan, output()))) == L("ask.plugin.hint.done", "Copy", "Replace"))
        #expect(AskPluginResultsView.hint(for: display(.failed(plan, AskPluginFailure(message: "x")))) == L("ask.plugin.hint.failed"))
        #expect(AskPluginResultsView.hint(for: display(.failed(plan, AskPluginFailure(message: "x", retry: false))))
            == L("ask.plugin.hint.waiting"))
        #expect(AskPluginResultsView.key(.enter) == "↩" && AskPluginResultsView.key(.optionEnter) == "⌥↩")
        #expect(AskPluginResultsView.key(.commandR) == "⌘R" && AskPluginResultsView.key(.commandD) == "⌘D")
        #expect(AskPluginResultsView.key(nil) == nil)
        #expect(display(.done(plan, output())).output?.body == "Hola")
        #expect(display(.waiting).output == nil && display(.waiting, highlighted: 1).asksAI)
    }
}

/// Opt-in renders of the launcher in keyword mode (set TYPEFLUX_ASK_SNAPSHOTS).
@Suite("Ask plugin snapshots", .serialized)
@MainActor
struct AskPluginVisualTests {
    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }

    @Test func renderKeywordMode() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let selection = "This update fixes the launcher drifting on external displays\nand steadies voice input during meetings."
        // name, editor text, selection, run it, height
        let cases: [(String, String, String?, Bool, CGFloat)] = [
            ("hint", "fy", nil, false, 300), ("selection-ready", "fy ", selection, false, 300),
            ("selection-done", "fy ", selection, true, 380), ("typed", "fy 明天下午三点开会，记得带上周报", nil, false, 380)
        ]
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for (file, text, selected, run, height) in cases {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                let device = AskTestTranslationEngine()
                let plugin = AskTranslatePlugin(onDevice: SnapshotEngine(), ai: device, aiName: { "MiniMax M3" },
                                                detector: AskLanguageDetector())
                fixture.model.plugins = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
                fixture.model.plugins.debounce = .milliseconds(1)
                fixture.model.launcherDraft = AskDraft(text: text, includeScreenshot: false, selection: selected,
                                                       source: "Google Chrome — Release notes", sourceBundleID: "com.google.Chrome")
                let view = AskLauncherView(model: fixture.model, onDismiss: {}).environment(\.askGlassMaterialOverride, .opaque)
                if run {
                    // Let the chip form and the plan land, then press Return's equivalent.
                    let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: height),
                                                    styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = NSHostingView(rootView: view)
                    window.orderFront(nil)
                    for _ in 0 ..< 200 where fixture.model.plugins.plan == nil { try await Task.sleep(for: .milliseconds(5)) }
                    fixture.model.plugins.run()
                    for _ in 0 ..< 200 where fixture.model.plugins.output == nil { try await Task.sleep(for: .milliseconds(5)) }
                    window.orderOut(nil)
                }
                try await render(view, size: NSSize(width: AskMetrics.launcherWidth, height: height), appearance: appearance,
                                 file: root.appendingPathComponent("plugin-\(file)-\(name).png"))
            }
        }
    }
}

/// Real-looking translations for the screenshots.
private struct SnapshotEngine: AskTranslationEngine {
    func canTranslate(from source: String?, to target: String) async -> Bool { true }
    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        if text.hasPrefix("This update") { return "这次更新修复了外接显示器上启动器位置偏移的问题，并让会议中的语音输入更加稳定。" }
        return "There is a meeting at 3 p.m. tomorrow; remember to bring the weekly report."
    }
}
