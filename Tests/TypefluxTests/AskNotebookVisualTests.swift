import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Opens the real notes window with sample notes and, when TYPEFLUX_NOTEBOOK_SNAPSHOTS
/// names a folder, captures it with `screencapture` so the glass backdrop is included
/// (`docs/design/notebook-redesign/`). Without the variable it only checks the window builds.
@Suite("Notebook window visuals", .serialized, .exclusiveUIState)
@MainActor
struct AskNotebookVisualTests {
    static let answer = """
    ## 结论

    800 万条、1536 维、p95 < 50ms：**选 HNSW**。IVFFlat 只在内存紧张、能接受召回下降时考虑。

    ## 对比

    | | HNSW | IVFFlat |
    |---|---|---|
    | 召回 | 高（ef_search 可调） | 取决于 probes |
    | 建索引 | 慢，占内存多 | 快，需先有数据 |

    ## 推荐参数

    ```sql
    CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
    ```

    ### 上线前检查

    - [x] `maintenance_work_mem` 调到 8GB 以上再建索引
    - [ ] 用真实查询压测 ef_search 40 / 80 / 120
    - [ ] 监控索引大小，预留 1.5 倍内存
    """

    private func seed(_ store: SQLiteAskNoteStore) -> UUID {
        let now = Date().timeIntervalSince1970
        var chat = AskNote(title: "Postgres 向量索引怎么选", body: Self.answer, command: "", keyword: "",
                           input: "我们有 800 万条 1536 维向量，召回要 p95 < 50ms，HNSW 和 IVFFlat 怎么选？",
                           model: "Claude Sonnet", tags: ["数据库"], pinned: true,
                           createdAt: Date(timeIntervalSince1970: now - 1800), updatedAt: Date(timeIntervalSince1970: now - 600),
                           source: .chat, conversationID: "conv")
        chat.originalBody = Self.answer + "\n"
        chat.editedAt = Date(timeIntervalSince1970: now - 600)
        store.save(chat)
        store.save(AskNote(title: "解释 · hell cat", body: "“地狱猫”（hell cat）通常指两种常见意思：\n\n1. **一种绰号**：形容凶猛、难以对付的人或动物。\n2. **一种战斗机**：二战美国海军的 **F6F Hellcat**。",
                           command: "解释", keyword: "ex", input: "hell cat", model: "gpt-5-mini", sourceApp: "Google Chrome",
                           tags: ["英语"], createdAt: Date(timeIntervalSince1970: now - 3600),
                           updatedAt: Date(timeIntervalSince1970: now - 3600)))
        store.save(AskNote(title: "下周发布清单", body: "- [x] 笔记本改版设计评审\n- [x] 截图 OCR 回归测试\n- [ ] 更新 App Store 截图\n- [ ] 写发布说明",
                           command: "", keyword: "", input: "", tags: ["工作"], pinned: true,
                           createdAt: Date(timeIntervalSince1970: now - 90000), updatedAt: Date(timeIntervalSince1970: now - 90000),
                           source: .manual))
        store.save(AskNote(title: "截图取字 · 周会白板", body: "### Q4 目标\n\n1. 日活 +20%\n2. 付费转化 3.5% → 5%",
                           command: "截图取字", keyword: "ocr", input: "", tags: ["工作"],
                           createdAt: Date(timeIntervalSince1970: now - 92000), updatedAt: Date(timeIntervalSince1970: now - 92000),
                           source: .screenshot))
        store.save(AskNote(title: "总结 · Swift 6 严格并发迁移", body: "## 要点\n\n- 先开 `-strict-concurrency=complete`，按警告逐个修。\n- `@MainActor` 标在 UI 类型上。",
                           command: "总结", keyword: "sum", input: "https://www.swift.org/migration", sourceApp: "Safari",
                           tags: ["Swift"], createdAt: Date(timeIntervalSince1970: now - 3 * 86400),
                           updatedAt: Date(timeIntervalSince1970: now - 3 * 86400)))
        store.save(AskNote(title: "Vim 常用命令", body: "| 命令 | 作用 |\n|---|---|\n| `ciw` | 改写当前词 |",
                           command: "", keyword: "", input: "", createdAt: Date(timeIntervalSince1970: now - 20 * 86400),
                           updatedAt: Date(timeIntervalSince1970: now - 20 * 86400), source: .import))
        return chat.id
    }

    private func capture(_ window: NSWindow, _ name: String) async throws {
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_NOTEBOOK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), root.appendingPathComponent(name).path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func theWindowDrawsItsStates(style: InterfaceStyle) async throws {
        _ = NSApplication.shared
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let store = makeTestNotes()
        let chat = seed(store)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "notebook-visual-\(UUID().uuidString)")!)
        settings.interfaceStyle = style
        let controller = AskNotesWindowController()
        var dark = true
        controller.configure(store: store, settings: settings, askAI: { _ in }, openConversation: { _ in }) {
            NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        controller.show(selecting: chat)
        let window = try #require(controller.window)
        let model = try #require(controller.model)
        defer { window.close() }
        window.setFrame(NSRect(x: 80, y: 80, width: 1320, height: 800), display: true)
        let prefix = style == .liquidGlass ? "glass" : "classic"
        try await capture(window, "\(prefix)-1-read-dark.png")
        #expect(model.selected?.id == chat && model.mode == .read)
        #expect(model.notes.first { $0.source == .manual }?.excerpt.contains("[x]") == false, "task boxes stay out of excerpts")

        dark = false
        window.appearance = NSAppearance(named: .aqua)
        try await capture(window, "\(prefix)-2-read-light.png")
        window.appearance = NSAppearance(named: .darkAqua)

        model.setMode(.edit)
        try await capture(window, "\(prefix)-3-edit.png")
        model.setMode(.split)
        try await capture(window, "\(prefix)-4-split.png")
        model.setMode(.read)

        model.searchText = "HNSW"
        try await capture(window, "\(prefix)-5-search.png")
        model.searchText = ""

        model.setSelecting(true)
        model.pickAll()
        try await capture(window, "\(prefix)-6-select.png")
        model.setSelecting(false)

        model.deleteSelected()
        try await capture(window, "\(prefix)-7-deleted.png")
        model.scope = .trash
        try await capture(window, "\(prefix)-8-trash.png")
        #expect(model.notes.count == 1)
        model.scope = .all

        model.createNote(title: "读书笔记 · 设计数据密集型应用")
        model.draftBody = "## 第 5 章 复制\n\n- **单主复制**：写入只走主库\n- [ ] 读己之写\n\n> 复制延迟不可避免。"
        try await capture(window, "\(prefix)-9-new.png")
        model.setMode(.read)

        let empty = AskNotesWindowController()
        empty.configure(store: makeTestNotes(), settings: settings, askAI: nil) { NSAppearance(named: .aqua) }
        empty.show()
        let emptyWindow = try #require(empty.window)
        defer { emptyWindow.close() }
        emptyWindow.setFrame(NSRect(x: 120, y: 120, width: 1100, height: 700), display: true)
        try await capture(emptyWindow, "\(prefix)-10-empty-light.png")
        #expect(empty.model?.notes.isEmpty == true)
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func minimumWindowKeepsActionsAndSplitEditorReachable(style: InterfaceStyle) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previous) }
        let store = makeTestNotes()
        let chat = seed(store)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "notebook-minimum-\(UUID().uuidString)")!)
        settings.interfaceStyle = style
        let controller = AskNotesWindowController()
        var openedConversation: String?
        controller.configure(store: store, settings: settings, askAI: { _ in }, openConversation: {
            openedConversation = $0
        }) {
            NSAppearance(named: .darkAqua)
        }
        controller.show(selecting: chat)
        let window = try #require(controller.window)
        let model = try #require(controller.model)
        defer { window.close() }
        window.setContentSize(AskNotesWindowController.minimumSize)
        let prefix = style == .liquidGlass ? "glass" : "classic"
        try await capture(window, "\(prefix)-11-minimum-read.png")
        try checkReadControls(window)
        let source = try accessibilityButton(L("ask.notes.openConversation"), in: window)
        #expect(accessibilityFrame(source).height <= 28, "the source action stays on one line")
        try click(accessibilityFrame(source), in: window)
        try await waitForUI { openedConversation == "conv" }
        #expect(openedConversation == "conv", "the compact source action remains clickable")
        let copy = try #require(accessibilityElement(L("ask.plugin.action.copy"),
                                                     attribute: "accessibilityLabel", in: window))
        var copied: String?
        model.copy = { copied = $0 }
        try click(accessibilityFrame(copy), in: window)
        try await waitForUI { copied == model.selected?.body }
        #expect(copied == model.selected?.body, "the compact copy action remains clickable")
        model.notice = nil
        try SettingsBehaviorTestSupport.button(L("ask.notes.mode.split"), in: window).press()
        try await waitForUI { model.mode == .split }
        #expect(model.mode == .split, "the mode picker remains clickable")
        try await capture(window, "\(prefix)-12-minimum-split.png")
        try await checkSplitControls(window, model: model)
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func resizingKeepsNotesAndActionsInsideTheirColumns(style: InterfaceStyle) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previous) }
        let store = makeTestNotes()
        let chat = seed(store)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "notebook-resizing-\(UUID().uuidString)")!)
        settings.interfaceStyle = style
        let controller = AskNotesWindowController()
        controller.configure(store: store, settings: settings, askAI: { _ in }, openConversation: { _ in }) {
            NSAppearance(named: .darkAqua)
        }
        controller.show(selecting: chat)
        let window = try #require(controller.window)
        let model = try #require(controller.model)
        defer { window.close() }
        for width in [1320, 1100, 1090, 940, 780, 680, 940, 1320] {
            window.setContentSize(NSSize(width: width, height: 620))
            try await capture(window, "resize-\(style.rawValue)-\(width)-read.png")
            try checkReadControls(window)
            let row = try #require(accessibilityElement("ask.notes.row", in: window))
            let content = try #require(window.contentView)
            let reader = try #require(descendants(content).compactMap { $0 as? AskNoteReaderText.ReaderView }.first)
            let readerFrame = screenFrame(reader, in: window)
            #expect(accessibilityFrame(row).maxX < readerFrame.minX,
                    "the list must not overlap the note during resizing")
            #expect(readerFrame.width >= 300 && readerFrame.width <= 680
                    && readerFrame.maxX <= window.frame.maxX + 1)
            #expect(model.selectedID == chat, "resizing keeps the selected note")

        }
        model.setMode(.split)
        let draft = "## Draft kept during resizing\n\n" + Self.answer
        model.draftBody = draft
        for width in [1320, 940, 680, 1320] {
            window.setContentSize(NSSize(width: width, height: 620))
            try await capture(window, "resize-\(style.rawValue)-\(width)-split.png")
            let content = try #require(window.contentView)
            let views = descendants(content)
            let editor = try #require(views.compactMap { $0 as? AskMarkdownEditor.EditorView }.first)
            let editorScroll = try #require(editor.enclosingScrollView)
            let preview = try #require(views.compactMap { $0 as? AskNoteReaderText.ReaderView }.first)
            let editorFrame = screenFrame(editorScroll, in: window)
            let previewFrame = screenFrame(preview, in: window)
            #expect(!editorFrame.intersects(previewFrame), "editor and preview never overlap")
            #expect(editorFrame.width >= 200 && previewFrame.width >= 200)
            #expect(model.mode == .split && model.draftBody == draft && editor.string == draft,
                    "switching the split orientation keeps unsaved text")
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func resultWindowKeepsItsIconToolbarReachableWhileResizing(style: InterfaceStyle) async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let recorder = AskResultServicesRecorder()
        let controller = AskResultWindowController()
        controller.defaults = UserDefaults(suiteName: "result-resizing-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: controller.defaults)
        settings.interfaceStyle = style
        controller.interfaceStyle = InterfaceStyleObserver(settings: settings)
        controller.appearance = { NSAppearance(named: .darkAqua) }
        let document = AskResultDocument(title: "Explain", keyword: "ex", model: "A long model name",
            input: "hell cat", body: Self.answer, state: .done,
            sourceApp: "An application with a very long name", sourceBundleID: "com.apple.Notes",
            regenerate: { _ in "Regenerated" }, services: recorder.services)
        controller.present(document)
        let window = try #require(NSApp.windows.first {
            $0.delegate === controller
                && ($0.contentView as? NSHostingView<AskResultWindowView>)?.rootView.document === document
        })
        defer { window.close() }
        for width in [900, 580, 480, 360, 580] {
            window.setContentSize(NSSize(width: width, height: 420))
            try await capture(window, "result-resize-\(style.rawValue)-\(width).png")
            let close = try #require(window.standardWindowButton(.closeButton))
            let pin = try #require(accessibilityElement("ask.result.pin", in: window))
            let closeFrame = screenFrame(close, in: window)
            let pinFrame = accessibilityFrame(pin)
            #expect(abs(closeFrame.midY - pinFrame.midY) <= 2,
                    "native window controls and title actions share one row, without an empty title strip")
            #expect(window.frame.maxY - pinFrame.midY <= AskResultWindowView.titleBarHeight,
                    "title actions stay at the top of the window")
            var lastMaxX = window.frame.minX
            for identifier in ["copy", "copyRich", "insert", "regenerate", "askAI"] {
                let button = try #require(accessibilityElement("ask.result." + identifier, in: window))
                let frame = accessibilityFrame(button)
                #expect(frame.width >= 28 && frame.height >= 28, "\(identifier) has a usable icon hit target")
                #expect(frame.minX >= lastMaxX && frame.maxX <= window.frame.maxX + 1,
                        "all toolbar actions fit without overlap")
                lastMaxX = frame.maxX
            }
        }
        let insert = try #require(accessibilityElement("ask.result.insert", in: window))
        #expect(accessibilityValue("accessibilityHelp", of: insert)?.contains("⌥↩") == true,
                "the icon's tooltip includes its shortcut")
        try click(accessibilityFrame(insert), in: window)
        try await waitForUI { !recorder.inserted.isEmpty }
        #expect(recorder.inserted.first?.0 == document.body)
        let ask = try #require(accessibilityElement("ask.result.askAI", in: window))
        try click(accessibilityFrame(ask), in: window)
        try await waitForUI { !recorder.asked.isEmpty }
        #expect(!recorder.asked.isEmpty, "the last action remains clickable")
        window.appearance = NSAppearance(named: .aqua)
        try await capture(window, "result-titlebar-\(style.rawValue)-light.png")
        settings.interfaceStyle = style == .classic ? .liquidGlass : .classic
        #expect(controller.interfaceStyle?.style == settings.interfaceStyle,
                "an open result window follows the app-wide interface setting")
        settings.interfaceStyle = style
        window.close()
        var note = makeTestNote("小名推荐（男女通用）", body: "## 小名推荐\n\n- 糯糯：软糯可爱\n- 岁岁：岁岁平安")
        note.command = ""
        note.source = .manual
        let noteDocument = controller.open(note)
        let noteWindow = try #require(NSApp.windows.first {
            $0.delegate === controller
                && ($0.contentView as? NSHostingView<AskResultWindowView>)?.rootView.document === noteDocument
        })
        defer { noteWindow.close() }
        #expect(noteWindow.title == note.title)
        noteWindow.setContentSize(NSSize(width: 580, height: 420))
        for dark in [true, false] {
            noteWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await capture(noteWindow, "note-titlebar-\(style.rawValue)-\(dark ? "dark" : "light").png")
        }
    }

    private func checkReadControls(_ window: NSWindow) throws {
        for identifier in ["notes.copy", "notes.pin", "notes.edit", "notes.delete"] {
            #expect(window.toolbar?.items.isEmpty == false, "the native toolbar owns library actions")
            let action = accessibilityElement("typeflux.toolbar." + identifier, in: window)
            // At small sizes AppKit can place actions in its native overflow menu.
            if let action {
                let frame = accessibilityFrame(action)
                #expect(frame.minX >= window.frame.minX - 1 && frame.maxX <= window.frame.maxX + 1)
            }
        }
        #expect(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true)
    }

    private func checkSplitControls(_ window: NSWindow, model: AskNotesViewModel) async throws {
        let content = try #require(window.contentView)
        let views = descendants(content)
        let editor = try #require(views.compactMap { $0 as? AskMarkdownEditor.EditorView }.first)
        let editorScroll = try #require(editor.enclosingScrollView)
        let editorFrame = screenFrame(editorScroll, in: window)
        let preview = try #require(views.compactMap { $0 as? AskNoteReaderText.ReaderView }.first)
        let previewFrame = screenFrame(preview, in: window)
        #expect(editorFrame.width >= 100 && previewFrame.width >= 100, "both split columns remain usable")
        if previewFrame.maxY <= editorFrame.minY {
            #expect(previewFrame.maxY <= editorFrame.minY, "stacked editing keeps the preview below the editor")
        } else {
            #expect(editorFrame.maxX <= previewFrame.minX, "the editor cannot overlap the rendered preview")
        }
        if let scrolling = views.compactMap({ $0 as? NSScrollView }).first(where: {
            let frame = screenFrame($0, in: window)
            return frame.height <= 60 && frame.minY >= editorFrame.maxY - 1
                && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 20
        }) {
            let formatFrame = screenFrame(scrolling, in: window)
            #expect(formatFrame.minX >= editorFrame.minX - 1 && formatFrame.maxX <= editorFrame.maxX + 1)
            let document = try #require(scrolling.documentView)
            scrolling.contentView.scroll(to: NSPoint(x: max(0, document.bounds.width - scrolling.contentView.bounds.width),
                                                     y: 0))
            scrolling.reflectScrolledClipView(scrolling.contentView)
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let table = try #require(accessibilityElement(L("ask.notes.format.table"),
                                                      attribute: "accessibilityLabel", in: window))
        let tableFrame = accessibilityFrame(table)
        #expect(tableFrame.minX >= editorFrame.minX - 1 && tableFrame.maxX <= editorFrame.maxX + 1,
                "the last formatting action fits or becomes reachable by scrolling")
        let before = model.draftBody
        try click(tableFrame, in: window)
        try await waitForUI { model.draftBody != before }
        #expect(model.draftBody != before && model.draftBody.contains("|---|---|"),
                "the last formatting action is reachable after scrolling")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitForUI(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func screenFrame(_ view: NSView, in window: NSWindow) -> NSRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func accessibilityElement(_ value: String, attribute: String = "accessibilityIdentifier",
                                      in window: NSWindow) -> NSObject? {
        AskLibraryTestSupport.elements(in: window).first { $0.value(attribute) as? String == value }?.object
    }

    private func accessibilityButton(_ label: String, in window: NSWindow) throws -> NSObject {
        try SettingsBehaviorTestSupport.button(label, in: window).object
    }

    private func accessibilityFrame(_ element: NSObject) -> NSRect {
        SettingsBehaviorTestSupport.Element(object: element).frame
    }

    private func click(_ frame: NSRect, in window: NSWindow) throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

}
