import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Draws the result card, the result window and the notes window; writes PNGs when
/// TYPEFLUX_ASK_SNAPSHOTS is set (compare with `docs/design/ai-command-results/`).
@Suite("AI prompt result rendering", .serialized)
@MainActor
struct AskNotesRenderTests {
    static let markdown = """
    比较优势（Comparative Advantage）是经济学里解释**“为什么贸易对双方都有好处”**的核心概念。

    **关键点：**
    - 比较的不是“谁绝对更强”，而是“谁放弃的代价更小”（机会成本）。
    - 只要两边的机会成本不同，分工 + 交换就能让总产出变多。

    > 绝对优势看效率高低，比较优势看机会成本高低。
    """

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, name: String) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func withChinese(_ body: () async throws -> Void) async rethrows {
        let previous = AppLocalization.shared.language
        let snapshots = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] != nil
        if snapshots { AppLocalization.shared.setLanguage(.simplifiedChinese) }
        defer { if snapshots { AppLocalization.shared.setLanguage(previous) } }
        try await body()
    }

    @Test func theResultCardDrawsMarkdownWithTheStarAndWindowButtons() async throws {
        _ = NSApplication.shared
        try await withChinese {
            let plugin = AskPromptPlugin(generator: nil, modelName: { "gpt-5-mini" }, savesNotes: true)
            let request = AskPluginRequest(text: "比较优势（Comparative Advantage）", origin: .selection,
                                           keyword: AskPromptPlugin.keywords[2], options: AskPromptPlugin.keywords[2].options,
                                           interfaceLanguage: .simplifiedChinese)
            let plan = await plugin.plan(request)
            let generator = AskTestTextGenerator()
            generator.pieces = [Self.markdown]
            let output = try await AskPromptPlugin(generator: generator, modelName: { "gpt-5-mini" }, savesNotes: true)
                .run(request, plan: plan).noteSaving(true)
            for (comparing, dark, name) in [(false, true, "1-card-markdown.png"), (true, false, "2-card-compare-light.png")] {
                let display = AskPluginDisplay(title: plugin.title, symbol: plugin.symbol, phase: .done(plan, output),
                                               comparing: comparing)
                let view = AskPluginResultsView(display: display, question: "", onMain: {}, onAction: { _ in },
                                                onAskAI: {}, onHighlight: { _ in })
                    .padding(.horizontal, AskMetrics.launcherGutter)
                try await render(view, size: NSSize(width: AskMetrics.launcherWidth,
                                                    height: AskPluginResultsView.height(for: display) + 10),
                                 dark: dark, name: name)
            }
            let streaming = AskPluginDisplay(title: plugin.title, symbol: plugin.symbol, phase: .running(plan),
                                             partial: output.noteSaving(false), savesNoteWhenDone: true)
            try await render(AskPluginResultsView(display: streaming, question: "", onMain: {}, onAction: { _ in },
                                                  onAskAI: {}, onHighlight: { _ in }),
                             size: NSSize(width: AskMetrics.launcherWidth, height: 520), dark: true,
                             name: "3-card-streaming-save.png")
            #expect(AskPluginResultsView.hint(for: streaming) == L("ask.plugin.hint.running"))
            #expect(AskPluginResultsView.key(.commandO) == "⌘O")
        }
    }

    @Test func theResultWindowDrawsItsStates() async throws {
        _ = NSApplication.shared
        try await withChinese {
            let recorder = AskResultServicesRecorder()
            let done = AskResultDocument(title: "解释", keyword: "ex", model: "gpt-5-mini",
                                         input: "比较优势（Comparative Advantage）", body: Self.markdown, state: .done,
                                         sourceApp: "备忘录", sourceBundleID: "com.apple.Notes",
                                         regenerate: { _ in "" }, services: recorder.services)
            done.toggleNote()
            done.pinned = true
            try await render(AskResultWindowView(document: done) {}, size: NSSize(width: 580, height: 620), dark: true,
                             name: "4-window.png")
            let streaming = AskResultDocument(title: "总结", keyword: "sum", model: nil, input: "", body: "## 会议要点\n\n1. **Q4",
                                              state: .streaming, services: recorder.services)
            streaming.toggleNote()
            try await render(AskResultWindowView(document: streaming) {}, size: NSSize(width: 580, height: 420),
                             dark: false, name: "5-window-streaming-light.png")
            let failed = AskResultDocument(title: "总结", keyword: "sum", model: nil, input: "x", body: "",
                                           state: .failed("出错了"), sourceBundleID: "gone.app",
                                           services: recorder.services)
            try await render(AskResultWindowView(document: failed) {}, size: NSSize(width: 480, height: 360),
                             dark: true, name: "6-window-failed.png")
            let note = AskResultDocument(note: makeTestNote(body: Self.markdown), services: recorder.services)
            try await render(AskResultWindowView(document: note) {}, size: NSSize(width: 480, height: 400),
                             dark: true, name: "7-window-note.png")
        }
    }

    @Test func theNotesWindowDrawsListsAndEditing() async throws {
        _ = NSApplication.shared
        try await withChinese {
            let store = makeTestNotes()
            let now = Date().timeIntervalSince1970
            store.save(makeTestNote("解释 · 比较优势（Comparative Advantage）", body: Self.markdown, command: "解释",
                                    input: "比较优势（Comparative Advantage）", tags: ["读书"], at: now - 60))
            store.save(makeTestNote("润色 · 产品发布邮件开头", body: "Hi all,\n\nWe are **excited** to announce …",
                                    command: "润色", input: "hi all we are exciting", tags: ["工作", "邮件"],
                                    pinned: true, at: now - 3600))
            store.save(makeTestNote("总结 · 《思考，快与慢》第 3 章", body: "## 系统 1 与系统 2\n\n- **系统 1**：快速、自动",
                                    command: "总结", input: "（第 3 章正文）", tags: ["读书"], at: now - 86400 * 3))
            let model = AskNotesViewModel(store: store, notificationCenter: NotificationCenter())
            model.askAI = { _ in }
            model.reveal(model.notes.first { $0.command == "解释" }?.id)
            try await render(AskNotesView(model: model) {}, size: NSSize(width: 1080, height: 700), dark: true,
                             name: "8-notes.png")
            model.beginEditing()
            model.draftBody = "## 编辑\n\n- **一** 二"
            try await render(AskNotesView(model: model) {}, size: NSSize(width: 1080, height: 700), dark: false,
                             name: "9-notes-edit-light.png")
            model.cancelEditing()
            model.deleteSelected()
            try await render(AskNotesView(model: model) {}, size: NSSize(width: 1080, height: 700), dark: true,
                             name: "10-notes-deleted.png")
            let empty = AskNotesViewModel(store: makeTestNotes(), notificationCenter: NotificationCenter())
            try await render(AskNotesView(model: empty) {}, size: NSSize(width: 900, height: 560), dark: true,
                             name: "11-notes-empty.png")
            #expect(AskNotesView.shortDate(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 86400 * 40))
                != AskNotesView.shortDate(Date(timeIntervalSince1970: 86400 * 40), now: Date(timeIntervalSince1970: 86400 * 40)))
        }
    }
}
