import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Item lists (`{"items": …}`, Alfred's Script Filter format) and Markdown output:
/// parsing and its tolerance, what each row's keys do, and how the plugin shows them.
@Suite("Ask workflow item lists")
struct AskWorkflowItemListTests {
    /// The example in `docs/design/ask-launcher-workflows.md` §4.2.
    static let alfred = #"""
    {
      "items": [
        {
          "uid": "ABC-123",
          "title": "ABC-123 登录页在 Safari 上白屏",
          "subtitle": "进行中 · 张三 · 2 小时前",
          "arg": "https://jira.example.com/browse/ABC-123",
          "icon": { "path": "icons/bug.png" },
          "autocomplete": "ABC-123",
          "valid": true,
          "action": "open",
          "mods": {
            "alt": { "subtitle": "写回", "arg": "ABC-123 登录页在 Safari 上白屏", "action": "paste" },
            "copy": { "arg": "https://jira.example.com/browse/ABC-123" },
            "cmd": { "arg": "ignored" }
          },
          "quicklookurl": "https://jira.example.com/browse/ABC-123"
        }
      ],
      "rerun": 2.0,
      "variables": { "scope": "mine" }
    }
    """#

    @Test func `the Alfred example reads every field Typeflux uses`() throws {
        let list = try #require(AskWorkflowItemList.parse(Self.alfred))
        #expect(list.rerun == 2 && list.variables == ["scope": "mine"])
        let item = try #require(list.items.first)
        #expect(item.uid == "ABC-123" && item.title == "ABC-123 登录页在 Safari 上白屏")
        #expect(item.subtitle == "进行中 · 张三 · 2 小时前" && item.arg == "https://jira.example.com/browse/ABC-123")
        #expect(item.icon == .file("icons/bug.png") && item.autocomplete == "ABC-123" && item.valid)
        #expect(item.action == .open && item.app == nil)
        #expect(item.alt == .init(arg: "ABC-123 登录页在 Safari 上白屏", subtitle: "写回", action: .paste, valid: nil))
        #expect(item.copy == "https://jira.example.com/browse/ABC-123")
    }

    @Test func `anything that is not a list is not one`() {
        for text in ["", "hello", "[1, 2]", #"{"text": "x"}"#, #"{"items": "x"}"#, #"{"items": [}"#,
                     "{\"items\": [] "] {
            #expect(AskWorkflowItemList.parse(text) == nil, "\(text)")
        }
        #expect(AskWorkflowItemList.parse("  \n{\"items\": []}\n")?.items == [], "surrounding blank lines are fine")
    }

    @Test func `careless scripts still get a list`() throws {
        let text = #"""
        {"items": [
          "not an object",
          {"subtitle": "no title"},
          {"title": "   "},
          {"title": 42, "arg": ["a", "b"], "valid": "no", "icon": "sf:star", "action": "fly"},
          {"title": "t", "arg": 7, "valid": 0, "icon": {"type": "fileicon", "path": "~/x"}, "text": {"copy": "c"}},
          {"title": "u", "valid": "TRUE", "icon": {"type": "filetype", "path": "public.folder"}, "uid": 9},
          {"title": "v", "valid": "maybe", "icon": {"path": ""}, "app": "", "mods": {"alt": {"valid": false}}},
          {"title": "w", "icon": 3, "autocomplete": true}
        ], "rerun": 0.1, "variables": {"n": 1, "b": true, "s": "x", "o": {"nested": 1}}}
        """#
        let list = try #require(AskWorkflowItemList.parse(text))
        #expect(list.items.map(\.title) == ["42", "t", "u", "v", "w"], "items without a title are skipped")
        #expect(list.items[0].arg == "a\nb" && !list.items[0].valid && list.items[0].icon == .symbol("star"))
        #expect(list.items[0].action == nil, "an unknown action falls back to the default")
        #expect(list.items[1].arg == "7" && !list.items[1].valid && list.items[1].icon == .fileIcon("~/x"))
        #expect(list.items[1].copy == "c", "Alfred's text.copy")
        #expect(list.items[2].valid && list.items[2].icon == .fileType("public.folder") && list.items[2].uid == "9")
        #expect(list.items[3].valid && list.items[3].icon == nil && list.items[3].app == nil)
        #expect(list.items[3].alt?.valid == false)
        #expect(list.items[4].icon == nil && list.items[4].autocomplete == "true")
        #expect(list.rerun == AskWorkflowItemList.minimumRerun, "reruns come no sooner than half a second")
        #expect(list.variables == ["n": "1", "b": "true", "s": "x"])
        #expect(AskWorkflowItemList.parse(#"{"items": [], "rerun": "3"}"#)?.rerun == 3)
        #expect(AskWorkflowItemList.parse(#"{"items": [], "rerun": true}"#)?.rerun == nil)
        let many = "{\"items\": [" + Array(repeating: #"{"title": "x"}"#, count: 250).joined(separator: ",") + "]}"
        #expect(AskWorkflowItemList.parse(many)?.items.count == AskWorkflowItemList.maximumItems)
    }

    @Test func `the display decides how stdout shows`() {
        let list = #"{"items": [{"title": "a"}]}"#
        #expect(AskWorkflowDecodedOutput.decode(list, display: .items) == .items(.init(items: [.init(title: "a")])))
        #expect(AskWorkflowDecodedOutput.decode(list, display: .auto) == .items(.init(items: [.init(title: "a")])))
        #expect(AskWorkflowDecodedOutput.decode(list, display: .text) == .text(list, note: nil))
        #expect(AskWorkflowDecodedOutput.decode(" plain \n", display: .auto) == .text("plain", note: nil))
        #expect(AskWorkflowDecodedOutput.decode("plain", display: .items)
            == .text("plain", note: L("ask.workflow.items.invalid")))
        #expect(AskWorkflowDecodedOutput.decode(#"{"text": "card"}"#, display: .items) == .text("card", note: nil))
        #expect(AskWorkflowDecodedOutput.decode(#"{"text": "card"}"#, display: .auto) == .text("card", note: nil))
        #expect(AskWorkflowDecodedOutput.decode("# Hi\n", display: .markdown) == .markdown("# Hi"))
        #expect(AskWorkflowDecodedOutput.decode("x", display: .none) == .text("x", note: nil))
        #expect(AskWorkflowDecodedOutput.decode("x", display: .image) == .text("x", note: nil))
        #expect(!AskWorkflowDecodedOutput.streams("{\"it", display: .items))
        #expect(!AskWorkflowDecodedOutput.streams(" {\"it", display: .auto))
        #expect(AskWorkflowDecodedOutput.streams("line", display: .auto))
        #expect(AskWorkflowDecodedOutput.streams("# a", display: .markdown) && AskWorkflowDecodedOutput.streams(
            "a",
            display: .text
        ))
        #expect(!AskWorkflowDecodedOutput.streams("a", display: .none))
    }
}

@Suite("Ask workflow item rows")
struct AskWorkflowItemRowTests {
    let folder = URL(fileURLWithPath: "/tmp/wf")
    var rows: AskWorkflowItemRows {
        AskWorkflowItemRows(folder: folder, home: "/Users/me", name: "Jira")
    }

    private func row(_ json: String, replaces: Bool = false) throws -> AskPluginItem {
        let list = try #require(AskWorkflowItemList.parse("{\"items\": [" + json + "]}"))
        return try #require(rows.items(list, replaces: replaces, original: "bug").first)
    }

    private func kind(_ item: AskPluginItem, _ shortcut: AskPluginAction.Shortcut) -> AskPluginAction.Kind? {
        item.actions.first { $0.shortcut == shortcut }?.kind
    }

    @Test func `Return opens links and paths and copies the rest`() throws {
        #expect(try kind(row(#"{"title": "a", "arg": "https://x.dev/a?b=1"}"#), .enter)
            == .open(#require(URL(string: "https://x.dev/a?b=1"))))
        #expect(try kind(row(#"{"title": "a", "arg": "~/Code/app"}"#), .enter)
            == .open(URL(fileURLWithPath: "/Users/me/Code/app")))
        #expect(try kind(row(#"{"title": "a", "arg": "file:///etc/hosts"}"#), .enter)
            == .open(URL(fileURLWithPath: "/etc/hosts")))
        #expect(try kind(row(#"{"title": "a", "arg": "192.168.1.2"}"#), .enter) == .copy("192.168.1.2"))
        #expect(try kind(row(#"{"title": "a", "arg": "javascript:alert(1)"}"#), .enter) == .copy("javascript:alert(1)"))
        #expect(try kind(row(#"{"title": "a", "arg": "https://"}"#), .enter) == .copy("https://"))
        let titled = try row(#"{"title": "a", "arg": "https://x.dev"}"#)
        #expect(titled.actions.first?.title == L("ask.plugin.action.open"))
    }

    @Test func `each action does what it says`() throws {
        #expect(try kind(row(#"{"title": "a", "arg": "x", "action": "copy"}"#), .enter) == .copy("x"))
        #expect(try kind(row(#"{"title": "a", "arg": "x", "action": "paste"}"#), .enter) == .writeBack("x"))
        #expect(try row(#"{"title": "a", "arg": "x", "action": "paste"}"#, replaces: true).actions.first?.title
            == L("ask.plugin.action.replace"))
        #expect(try kind(row(#"{"title": "a", "arg": "notes.txt", "action": "reveal"}"#), .enter)
            == .reveal(URL(fileURLWithPath: "/tmp/wf/notes.txt")))
        #expect(try kind(row(#"{"title": "a", "arg": "next", "action": "run"}"#), .enter) == .runWith("next"))
        #expect(try kind(row(#"{"title": "a", "arg": "why?", "action": "askAI"}"#), .enter) == .askAI("why?"))
        #expect(try kind(row(#"{"title": "a", "arg": "/p", "action": "open", "app": "Zed"}"#), .enter)
            == .openIn(URL(fileURLWithPath: "/p"), application: "Zed"))
        #expect(try row(#"{"title": "a", "arg": "/p", "action": "open", "app": "Zed.app"}"#).actions.first?.title
            == L("ask.plugin.action.openIn", "Zed"))
        #expect(try kind(row(#"{"title": "a", "arg": "https://x.dev", "app": "Zed"}"#), .enter)
            == .open(#require(URL(string: "https://x.dev"))), "links open in the browser")
        #expect(try kind(row(#"{"title": "a", "arg": "plain", "action": "open"}"#), .enter) == nil,
                "what cannot be opened does nothing")
        #expect(try kind(row(#"{"title": "a", "arg": "a\nb", "action": "reveal"}"#), .enter) == nil)
    }

    @Test func `option Return writes back unless the item says otherwise`() throws {
        #expect(try kind(row(#"{"title": "a", "arg": "x"}"#), .optionEnter) == .writeBack("x"))
        #expect(try kind(row(#"{"title": "a", "arg": "x", "mods": {"alt": {"arg": "y"}}}"#), .optionEnter)
            == .writeBack("y"))
        #expect(try kind(row(#"{"title": "a", "arg": "/p", "mods": {"alt": {"action": "reveal"}}}"#), .optionEnter)
            == .reveal(URL(fileURLWithPath: "/p")))
        #expect(try kind(row(#"{"title": "a", "arg": "x", "mods": {"alt": {"valid": false}}}"#), .optionEnter) == nil)
        #expect(try kind(row(#"{"title": "a", "arg": "x", "valid": false, "mods": {"alt": {"valid": true}}}"#),
                         .optionEnter) == .writeBack("x"))
    }

    @Test func `rows that cannot be acted on still complete and copy`() throws {
        let invalid = try row(#"{"title": "Log in first", "arg": "x", "valid": false}"#)
        #expect(kind(invalid, .enter) == nil && kind(invalid, .optionEnter) == nil && !invalid.valid)
        let deeper = try row(#"{"title": "Projects", "valid": false, "autocomplete": "proj "}"#)
        #expect(kind(deeper, .enter) == .runWith("proj ") && deeper.autocomplete == "proj ")
        #expect(deeper.actions.first?.title == L("ask.plugin.action.complete"))
        #expect(kind(deeper, .commandC) == .copy("Projects"), "⌘C copies the title without an arg")
        let noArg = try row(#"{"title": "a"}"#)
        #expect(kind(noArg, .enter) == nil && kind(noArg, .optionEnter) == nil)
        #expect(try kind(row(#"{"title": "a", "arg": "x", "mods": {"copy": {"arg": "c"}}}"#), .commandC) == .copy("c"))
        let asks = try row(#"{"title": "a", "subtitle": "b"}"#).actions.last
        #expect(asks?.kind == .askAI(L("ask.workflow.askAI", "Jira", "bug", "a\nb")) && asks?.shortcut == nil)
    }

    @Test func `ids icons and the empty list`() throws {
        let list = try #require(AskWorkflowItemList.parse(#"""
        {"items": [
          {"uid": "u1", "title": "a", "icon": {"path": "icons/a.png"}},
          {"title": "b", "icon": "~/b.png"},
          {"title": "c", "icon": "/abs/c.png"},
          {"title": "d", "icon": {"type": "fileicon", "path": "~/Code"}},
          {"title": "e", "icon": {"type": "filetype", "path": "public.folder"}},
          {"title": "f", "icon": "sf:wifi"}
        ]}
        """#))
        let items = rows.items(list, replaces: false, original: "")
        #expect(items.map(\.id) == ["uid:u1", "index:1", "index:2", "index:3", "index:4", "index:5"])
        #expect(items.map(\.icon) == [
            .image(URL(fileURLWithPath: "/tmp/wf/icons/a.png")), .image(URL(fileURLWithPath: "/Users/me/b.png")),
            .image(URL(fileURLWithPath: "/abs/c.png")), .fileIcon(URL(fileURLWithPath: "/Users/me/Code")),
            .fileType("public.folder"), .symbol("wifi")
        ])
        let empty = rows.items(.init(items: []), replaces: false, original: "")
        #expect(empty.count == 1 && empty[0].title == L("ask.workflow.items.empty") && !empty[0].valid)
        #expect(empty[0].actions.isEmpty)
    }

    @Test func `paths resolve inside the folder under home or as given`() {
        #expect(rows.fileURL("a/../b.txt") == URL(fileURLWithPath: "/tmp/wf/b.txt"))
        #expect(rows.fileURL("~") == URL(fileURLWithPath: "/Users/me"))
        #expect(rows.fileURL("  ") == nil)
        #expect(rows.openTarget("relative/path") == nil, "a bare relative path is text, not a file to open")
        #expect(rows.openTarget("HTTPS://X.dev") != nil, "schemes are matched in any case")
    }
}

@Suite("Ask plugin output with items")
struct AskPluginOutputItemTests {
    private func output(_ items: [AskPluginItem], selected: Int = 0) -> AskPluginOutput {
        var output = AskPluginOutput(body: "a\nb", original: "", meta: [], source: "zsh", actions: [
            AskPluginAction(kind: .rerun([:]), title: "Run again", symbol: "arrow.clockwise", shortcut: .commandR),
            AskPluginAction(kind: .askAI("whole"), title: "Ask", symbol: "bubble.left", shortcut: nil)
        ])
        output.items = items
        output.selectedItem = selected
        return output
    }

    private let first = AskPluginItem(id: "1", title: "a", actions: [
        AskPluginAction(kind: .copy("A"), title: "Copy", symbol: "doc", shortcut: .enter),
        AskPluginAction(kind: .askAI("about a"), title: "Ask", symbol: "bubble.left", shortcut: nil)
    ])
    private let invalid = AskPluginItem(id: "2", title: "b", valid: false)

    @Test func `the chosen row answers Return and the result the rest`() {
        let list = output([first, invalid])
        #expect(list.action(for: .enter)?.kind == .copy("A"))
        #expect(list.action(for: .commandR)?.kind == .rerun([:]))
        #expect(list.askAIAction?.kind == .askAI("about a"))
        let second = output([first, invalid], selected: 1)
        #expect(second.action(for: .enter) == nil, "no fallback to copying the titles")
        #expect(second.action(for: .commandC) == nil && second.action(for: .optionEnter) == nil)
        #expect(second.askAIAction?.kind == .askAI("whole"))
        #expect(output([first], selected: 5).selected == nil)
        #expect(output([]).action(for: .commandC)?.kind == .copy("a\nb"), "text results copy their body")
    }
}

@Suite("Ask plugin list views")
@MainActor
struct AskPluginListViewTests {
    private func display(_ items: [AskPluginItem], selected: Int = 0) -> AskPluginDisplay {
        var output = AskPluginOutput(body: "", original: "", meta: [], source: "", actions: [])
        output.items = items
        output.selectedItem = selected
        return AskPluginDisplay(
            title: "T",
            symbol: "star",
            phase: .done(AskPluginPlan(mode: .onSubmit, title: "p"), output)
        )
    }

    private func rows(_ count: Int) -> [AskPluginItem] {
        (0 ..< count).map { AskPluginItem(id: "\($0)", title: "\($0)") }
    }

    @Test func `lists grow to six rows then scroll`() {
        let one = AskPluginResultsView.mainHeight(display(rows(1)))
        let three = AskPluginResultsView.mainHeight(display(rows(3)))
        #expect(three - one == 2 * (AskPluginResultsView.itemHeight + AskPluginResultsView.itemSpacing))
        #expect(AskPluginResultsView.mainHeight(display(rows(6))) == AskPluginResultsView.mainHeight(display(rows(40))))
        #expect(AskPluginResultsView.itemsHeight(0) == AskPluginResultsView.itemHeight)
    }

    @Test func `the bottom bar names the chosen row's keys`() {
        let copy = AskPluginAction(kind: .copy("x"), title: "Copy", symbol: "doc", shortcut: .enter)
        let paste = AskPluginAction(
            kind: .writeBack("x"),
            title: "Insert",
            symbol: "text.insert",
            shortcut: .optionEnter
        )
        let items = [AskPluginItem(id: "a", title: "a", actions: [copy, paste]),
                     AskPluginItem(id: "b", title: "b", valid: false, autocomplete: "b ")]
        #expect(AskPluginResultsView.hint(for: display(items))
            == [L("ask.plugin.hint.action", "Copy"), L("ask.plugin.hint.option.enter", "Insert"),
                L("ask.plugin.hint.askAI")].joined(separator: " · "))
        #expect(AskPluginResultsView.hint(for: display(items, selected: 1))
            == [L("ask.plugin.hint.complete"), L("ask.plugin.hint.askAI")].joined(separator: " · "))
    }

    @Test func `markdown is measured as Ask draws it`() {
        let line = AskPluginResultsView.markdownHeight("one line")
        let table = AskPluginResultsView.markdownHeight("# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        #expect(line >= 22 && table > line)
        #expect(AskPluginResultsView.markdownHeight(String(repeating: "- item\n", count: 200))
            == AskPluginResultsView.maximumMarkdownHeight)
        #expect(AskPluginResultsView.markdownHeight("one line") == line, "measured once, then remembered")
    }

    @Test func `icons come from symbols files and types`() throws {
        #expect(AskPluginItemIcon.symbolName(.symbol("wifi")) == "wifi")
        #expect(AskPluginItemIcon.symbolName(.symbol("no.such.symbol.anywhere")) == nil)
        #expect(AskPluginItemIcon.symbolName(nil) == nil && AskPluginItemIcon.image(.symbol("wifi")) == nil)
        #expect(AskPluginItemIcon.image(.fileType("public.folder")) != nil)
        #expect(AskPluginItemIcon.image(.fileIcon(URL(fileURLWithPath: "/no/such/file"))) == nil)
        #expect(AskPluginItemIcon.image(.fileIcon(URL(fileURLWithPath: NSTemporaryDirectory()))) != nil)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("tf-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try data.write(to: png)
        #expect(AskPluginItemIcon.image(.image(png)) != nil)
        #expect(AskPluginItemIcon.image(.image(png)) != nil, "and again from the cache")
    }
}
