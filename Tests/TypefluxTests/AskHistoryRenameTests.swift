import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Inline conversation rename", .serialized, .exclusiveUIState)
@MainActor
struct AskHistoryRenameTests {
    @MainActor final class Recorder: NSObject, ObservableObject {
        @Published var title = "你好啊，老铁"
        var saves: [String] = []
        var fails = false
        var selections = 0
        var otherClicks = 0
    }

    @MainActor final class ClickTarget: NSView {
        var onClick: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick() }
    }

    @MainActor struct Row: View {
        @ObservedObject var recorder: Recorder
        var busy = false
        @Namespace private var selection

        var body: some View {
            AskHistoryRow(title: recorder.title, updatedAt: Date(), selected: true, busy: busy,
                          selectionSpace: selection, onSelect: { recorder.selections += 1 }, onRename: {
                recorder.saves.append($0)
                if recorder.fails { throw AskLocalError.message("Could not save") }
                recorder.title = $0
            }, onDelete: {})
            .padding(.horizontal, 8)
        }
    }

    @MainActor final class Host {
        let window: AskTestVoiceWindow
        let hosting: NSHostingView<AnyView>
        let recorder = Recorder()
        let button: ClickTarget

        init(style: InterfaceStyle = .classic, dark: Bool = false, busy: Bool = false) {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            let frame = NSRect(x: 0, y: 0, width: 248, height: 120)
            window = AskTestVoiceWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: frame)
            hosting = NSHostingView(rootView: AnyView(Row(recorder: recorder, busy: busy)
                .environment(\.interfaceStyle, style)
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .frame(width: 248, height: 44)
                .background(style.usesGlass ? AskTheme.surface : AskClassic.sidebar)))
            hosting.frame = NSRect(x: 0, y: 60, width: 248, height: 44)
            button = ClickTarget()
            button.onClick = { [recorder] in recorder.otherClicks += 1 }
            button.frame = NSRect(x: 12, y: 12, width: 80, height: 28)
            content.addSubview(hosting)
            content.addSubview(button)
            window.contentView = content
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.makeKeyAndOrderFront(nil)
            hosting.layoutSubtreeIfNeeded()
        }

        func close() { window.orderOut(nil); window.close() }

        func draw() {
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
        }

        var field: AskHistoryTitleEditor.Field? {
            func find(_ view: NSView) -> AskHistoryTitleEditor.Field? {
                if let field = view as? AskHistoryTitleEditor.Field { return field }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(hosting)
        }

        func beginRename() throws {
            hosting.layoutSubtreeIfNeeded()
            var seen = Set<ObjectIdentifier>()
            func actions(_ element: Any) -> [NSAccessibilityCustomAction] {
                guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
                let own = object.responds(to: NSSelectorFromString("accessibilityCustomActions"))
                    ? object.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? [] : []
                let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                    ? object.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
                return own + children.flatMap(actions)
            }
            let matches = (actions(window) + actions(hosting)).filter { $0.name == L("ask.title.rename") }
            let rename = try #require(matches.last)
            let handler = try #require(rename.handler)
            #expect(handler())
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    private func begin(_ host: Host) async throws -> NSTextView {
        try await settle()
        try host.beginRename()
        for _ in 0..<60 {
            host.draw()
            if let editor = host.field?.currentEditor() as? NSTextView { return editor }
            try await Task.sleep(for: .milliseconds(20))
        }
        let field = try #require(host.field)
        #expect(field.window === host.window)
        #expect(field.isEditable)
        return try #require(field.currentEditor() as? NSTextView)
    }

    private func key(_ text: String, code: UInt16, editor: NSTextView) async throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        editor.keyDown(with: event)
        try await settle()
    }

    @Test func returnSavesOnceAndStartsWithTheWholeTitleSelected() async throws {
        let host = Host()
        defer { host.close() }
        let editor = try await begin(host)
        #expect(editor.selectedRange() == NSRange(location: 0, length: host.recorder.title.utf16.count))
        editor.insertText("聊天标题设计", replacementRange: editor.selectedRange())
        try await key("\r", code: 36, editor: editor)
        host.window.makeFirstResponder(nil)
        #expect(host.recorder.saves == ["聊天标题设计"])
        #expect(host.recorder.title == "聊天标题设计")
        #expect(host.recorder.selections == 0)
        #expect(host.field == nil)
    }

    @Test func escapeAndEmptyOrUnchangedTitlesDoNotSave() async throws {
        for draft in ["Changed", "", "你好啊，老铁"] {
            let host = Host()
            defer { host.close() }
            let editor = try await begin(host)
            editor.insertText(draft, replacementRange: editor.selectedRange())
            try await key(draft == "Changed" ? "\u{1b}" : "\r", code: draft == "Changed" ? 53 : 36, editor: editor)
            #expect(host.recorder.saves.isEmpty)
            #expect(host.recorder.title == "你好啊，老铁")
            #expect(host.field == nil)
        }
    }

    @Test func anOutsideClickSavesAndStillDeliversTheClickedAction() async throws {
        let host = Host()
        defer { host.close() }
        let editor = try await begin(host)
        editor.insertText("Updated title", replacementRange: editor.selectedRange())
        let point = host.button.convert(NSPoint(x: 40, y: 14), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(down)
        try await settle()
        #expect(host.recorder.saves == ["Updated title"])
        #expect(host.recorder.title == "Updated title")
        #expect(host.recorder.otherClicks == 1)
        #expect(host.field == nil)
    }

    @Test func validationAndRequestFailuresKeepTheDraftEditableForRetry() async throws {
        let host = Host()
        defer { host.close() }
        var editor = try await begin(host)
        let tooLong = String(repeating: "a", count: 61)
        editor.insertText(tooLong, replacementRange: editor.selectedRange())
        try await key("\r", code: 36, editor: editor)
        #expect(host.recorder.saves.isEmpty)
        #expect(host.field?.stringValue == tooLong)
        editor = try #require(host.field?.currentEditor() as? NSTextView)
        host.recorder.fails = true
        editor.insertText("Keep my draft", replacementRange: editor.selectedRange())
        try await key("\r", code: 36, editor: editor)
        #expect(host.recorder.title == "你好啊，老铁")
        #expect(host.field?.stringValue == "Keep my draft")
        editor = try #require(host.field?.currentEditor() as? NSTextView)
        host.recorder.fails = false
        try await key("\r", code: 36, editor: editor)
        #expect(host.recorder.saves == ["Keep my draft", "Keep my draft"])
        #expect(host.recorder.title == "Keep my draft")
        #expect(host.field == nil)
    }

    @Test func markedChineseTextDoesNotConfirmOrCancelTheRename() throws {
        var results: [String?] = []
        let coordinator = AskHistoryTitleEditor.Coordinator { results.append($0) }
        let field = NSTextField()
        let editor = NSTextView()
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(results.isEmpty)
        editor.unmarkText()
        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(results.count == 1)
    }

    @Test func busyRowsCannotStartRenaming() async throws {
        let host = Host(busy: true)
        defer { host.close() }
        try await settle()
        try host.beginRename()
        try await settle()
        #expect(host.field == nil)
        #expect(host.recorder.saves.isEmpty)
    }

    @Test func editingFitsBothStylesWithoutChangingTheRowHeight() async throws {
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                let host = Host(style: style, dark: dark)
                defer { host.close() }
                _ = try await begin(host)
                host.hosting.layoutSubtreeIfNeeded()
                let field = try #require(host.field)
                #expect(field.bounds.width >= 140)
                #expect(field.bounds.height <= style.ask.sidebarRowHeight)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_RENAME_SCREENSHOTS"] {
                    let bitmap = try #require(host.hosting.bitmapImageRepForCachingDisplay(in: host.hosting.bounds))
                    host.hosting.cacheDisplay(in: host.hosting.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try png.write(to: root.appendingPathComponent("rename-\(style.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
