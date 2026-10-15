import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Draws the result card, the result window and the notes window; writes PNGs when
/// TYPEFLUX_ASK_SNAPSHOTS is set (compare with `docs/design/ai-command-results/`). The launcher card is
/// drawn light: its dark glass comes from the launcher panel, which a bare window lacks.
@Suite("AI prompt result rendering", .serialized, .exclusiveUIState)
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
            for (comparing, dark, name) in [(false, false, "1-card-markdown.png"), (true, false, "2-card-compare.png")] {
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
                             size: NSSize(width: AskMetrics.launcherWidth, height: 520), dark: false,
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
            await done.toggleNote()?.value
            done.pinned = true
            try await render(AskResultWindowView(document: done) {}, size: NSSize(width: 580, height: 620), dark: true,
                             name: "4-window.png")
            let streaming = AskResultDocument(title: "总结", keyword: "sum", model: nil, input: "", body: "## 会议要点\n\n1. **Q4",
                                              state: .streaming, services: recorder.services)
            await streaming.toggleNote()?.value
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
            for width in [360, 480, 900] {
                try await render(AskResultWindowView(document: note) {}, size: NSSize(width: width, height: 420),
                                 dark: true, name: "result-note-\(width).png")
                try await render(AskResultWindowView(document: done) {}, size: NSSize(width: width, height: 420),
                                 dark: false, name: "result-command-\(width).png")
            }
        }
    }

    @Test func theNotesWindowDrawsListsAndEditing() async throws {
        _ = NSApplication.shared
        try await withChinese {
            let store = makeTestNotes()
            let now = Date().timeIntervalSince1970
            try store.save(makeTestNote("解释 · 比较优势（Comparative Advantage）", body: Self.markdown, command: "解释",
                                    input: "比较优势（Comparative Advantage）", tags: ["读书"], at: now - 60))
            try store.save(makeTestNote("润色 · 产品发布邮件开头", body: "Hi all,\n\nWe are **excited** to announce …",
                                    command: "润色", input: "hi all we are exciting", tags: ["工作", "邮件"],
                                    pinned: true, at: now - 3600))
            try store.save(makeTestNote("总结 · 《思考，快与慢》第 3 章", body: "## 系统 1 与系统 2\n\n- **系统 1**：快速、自动",
                                    command: "总结", input: "（第 3 章正文）", tags: ["读书"], at: now - 86400 * 3))
            let model = AskNotesViewModel(store: store, notificationCenter: NotificationCenter())
        await model.waitForReload()
            model.askAI = { _ in }
            await model.reveal(model.notes.first { $0.command == "解释" }?.id)
            try await render(AskNotesView(model: model) {}, size: NSSize(width: 1080, height: 700), dark: true,
                             name: "8-notes.png")
            for width in [1320, 1100, 1090, 940, 780, 680] {
                try await render(AskNotesView(model: model) {}, size: NSSize(width: width, height: 620), dark: true,
                                 name: "notes-read-\(width).png")
            }
            await model.setMode(.split)
            for width in [1320, 940, 680] {
                try await render(AskNotesView(model: model) {}, size: NSSize(width: width, height: 620), dark: true,
                                 name: "notes-split-\(width).png")
            }
            await model.setMode(.read)
            model.beginEditing()
            model.draftBody = "## 编辑\n\n- **一** 二"
            try await render(AskNotesView(model: model) {}, size: NSSize(width: 1080, height: 700), dark: false,
                             name: "9-notes-edit-light.png")
            await model.cancelEditing()
            await model.deleteSelected()
            try await render(AskNotesView(model: model) {}, size: NSSize(width: 1080, height: 700), dark: true,
                             name: "10-notes-deleted.png")
            let empty = AskNotesViewModel(store: makeTestNotes(), notificationCenter: NotificationCenter())
        await empty.waitForReload()
            try await render(AskNotesView(model: empty) {}, size: NSSize(width: 900, height: 560), dark: true,
                             name: "11-notes-empty.png")
            #expect(AskNotesListRow.shortDate(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 86400 * 40))
                != AskNotesListRow.shortDate(Date(timeIntervalSince1970: 86400 * 40), now: Date(timeIntervalSince1970: 86400 * 40)))
        }
    }

    @Test func onlyMarkdownTasksReceiveInteractiveCheckboxLinks() async throws {
        let markdown = "Literal ☐ glyph\n\n```\n☑ code\n```\n\n- [ ] first\n- [x] second"
        let rendered = AskNoteReaderText.attributed(markdown, highlight: "first")
        var links: [String] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
            else if let value = value as? String { links.append(value) }
        }
        #expect(links == ["typeflux-task://0", "typeflux-task://1"])
        let text = rendered.string as NSString
        let literal = text.range(of: "☐")
        #expect(rendered.attribute(.link, at: literal.location, effectiveRange: nil) == nil)
        let highlighted = text.range(of: "first")
        #expect(rendered.attribute(.backgroundColor, at: highlighted.location, effectiveRange: nil) != nil)
        let done = text.range(of: "second")
        #expect(rendered.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil) != nil)
    }

}
