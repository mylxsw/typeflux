import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@Suite("Settings fidelity regressions", .exclusiveUIState)
@MainActor
struct SettingsFidelityTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: [720.0, 1100.0])
    func `toolbar source picker stays compact and changes the same filter`(width: Double) async throws {
        try await UI.withFixture { _ in
            var selected = VocabularyFilter.all
            let binding = Binding(get: { selected }, set: { selected = $0 })
            let picker = StudioToolbarPicker(L("vocabulary.table.source"), selection: binding) {
                ForEach(VocabularyFilter.allCases) { Text($0.title).tag($0) }
            }.environment(\.studioWindowWidth, width)
            try await UI.withWindow(picker, width: 400, height: 100) { window, host in
                let popups = UI.nativeViews(in: host).compactMap { $0 as? NSPopUpButton }
                if width < 1040 {
                    let popup = try #require(popups.first)
                    #expect(popup.frame.width < 200)
                    if popup.item(withTitle: VocabularyFilter.manual.title) != nil, let action = popup.action {
                        popup.selectItem(withTitle: VocabularyFilter.manual.title)
                        #expect(NSApp.sendAction(action, to: popup.target, from: popup))
                    } else {
                        // SwiftUI populates lazy menus only during tracking; exercise the installed binding.
                        binding.wrappedValue = .manual
                    }
                } else {
                    #expect(popups.isEmpty)
                    try UI.button(VocabularyFilter.manual.title, in: window).press()
                }
                #expect(selected == .manual)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func `keyword sheets keep placeholders inside left aligned inputs`(
        style: InterfaceStyle, dark: Bool
    ) async throws {
        try await UI.withFixture { _ in
            for kind in [AskKeywordKind.prompt, .web] {
                var draft = AskKeywordDraft(adding: kind)
                draft.keyword = "fixture"
                draft.title = ""
                draft.aliases = ["extra"]
                draft.prompt = "Summarize {input}."
                var saved: AskKeyword?
                let sheet = AskKeywordEditorSheet(draft: draft, keywords: [], workflows: [],
                                                   onSave: { saved = $0 }, onCancel: {})
                    .environment(\.interfaceStyle, style)
                try await UI.withWindow(sheet, width: 560, height: 580) { window, host in
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    try await UI.wait {
                        fields(in: host).contains { $0.isEditable && $0.stringValue == "fixture" }
                    }
                    let keyword = try #require(fields(in: host).first { $0.isEditable && $0.stringValue == "fixture" })
                    #expect(keyword.alignment != .right)
                    let name = try #require(fields(in: host).first { $0.placeholderString == draft.titlePlaceholder })
                    #expect(name.alignment != .right)
                    #expect(!fields(in: host).contains { !$0.isEditable && $0.stringValue == draft.titlePlaceholder })
                    if kind == .prompt {
                        let editor = try #require(UI.nativeViews(in: host).compactMap { $0 as? NSTextView }
                            .first { $0.string == draft.prompt })
                        #expect(editor.alignment != .right)
                    }
                    let scroll = try #require(formScroll(in: host))
                    try await UI.wait { scroll.hasVerticalScroller }
                    #expect(scroll.verticalScroller != nil)
                    scrollToBottom(scroll)
                    host.layoutSubtreeIfNeeded()
                    let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                    #expect(bounds.contains(try element("ask.settings.keywords.sheet.enabled", in: host).frame))
                    let enabled = try UI.button(L("ask.settings.keywords.sheet.add"), in: host)
                    #expect(bounds.contains(enabled.frame))
                    try element("ask.settings.keywords.sheet.save", in: host).press()
                    #expect(saved?.keyword == "fixture" && saved?.aliases == ["extra"])
                }
            }
        }
    }

    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func `form measurement preserves the installed scrollbar style`(scrollerStyle: NSScroller.Style) async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let scroll = NSScrollView(frame: container.bounds)
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = scrollerStyle
        container.addSubview(scroll)
        let measurement = TypefluxFormContentHeight.FormMeasurementView()
        container.addSubview(measurement)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { measurement.stopMeasuringForm(); window.contentView = nil; window.close() }
        let installedStyle = scroll.scrollerStyle
        var height: CGFloat?
        measurement.documentReport = { height = $0 }
        measurement.scheduleFormMeasurement()
        try await UI.wait { height != nil }
        #expect(scroll.scrollerStyle == installedStyle)
        #expect(scroll.hasVerticalScroller && scroll.verticalScroller != nil)
        #expect(try #require(height) >= 600)
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func `keyword sheet title and buttons align with the grouped cards`(style: InterfaceStyle, dark: Bool) async throws {
        try await UI.withFixture { _ in
            var draft = AskKeywordDraft(adding: .prompt)
            draft.keyword = "fixture"
            draft.prompt = "Summarize {input}."
            let sheet = AskKeywordEditorSheet(draft: draft, keywords: [], workflows: [], onSave: { _ in }, onCancel: {})
                .environment(\.interfaceStyle, style)
            try await UI.withWindow(sheet, width: 560, height: 780) { window, host in
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try await UI.wait { fields(in: host).contains { $0.isEditable && $0.stringValue == "fixture" } }
                let field = try #require(fields(in: host).first { $0.isEditable && $0.stringValue == "fixture" })
                let inputFrame = window.convertToScreen(field.convert(field.bounds, to: nil))
                let title = try element("typeflux.sheet.title", in: host)
                let save = try element("ask.settings.keywords.sheet.save", in: host)
                // The native card has its own small row inset; the sheet chrome aligns to the card edge.
                #expect(inputFrame.minX - title.frame.minX >= 0)
                #expect(inputFrame.minX - title.frame.minX <= 16)
                #expect(save.frame.maxX - inputFrame.maxX >= 0)
                #expect(save.frame.maxX - inputFrame.maxX <= 16)
            }
        }
    }

    @Test(arguments: [720.0, 1100.0])
    func `vocabulary toolbar places import before add in the right action group`(width: Double) async throws {
        try await UI.withFixture { settings in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let controller = SettingsWindowController()
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                            initialSection: .vocabulary)
            let window = try #require(controller.window)
            defer { TypefluxNavigationTestSupport.closeWindow(window) }
            window.setContentSize(NSSize(width: width, height: 500))
            let identifiers = ["typeflux.toolbar.vocabulary.import", "typeflux.toolbar.vocabulary.add"]
            try await UI.wait {
                identifiers.allSatisfy { identifier in
                    AskLibraryTestSupport.elements(in: window).contains {
                        $0.value("accessibilityIdentifier") as? String == identifier
                            && !$0.frame.isEmpty && window.frame.contains($0.frame)
                    }
                }
            }
            // Native toolbar roots precede SwiftUI's duplicate AX proxies; identify both controls explicitly.
            let frames = try identifiers.map { identifier in
                try #require(AskLibraryTestSupport.elements(in: window).first {
                    $0.value("accessibilityIdentifier") as? String == identifier
                        && !$0.frame.isEmpty && window.frame.contains($0.frame)
                }).frame
            }
            let transfer = frames[0]
            let add = frames[1]
            #expect(transfer.maxX <= add.minX + 1)
            #expect(transfer.minX > window.frame.midX)
            #expect(!AskWorkspaceTestAccessibility.elements(in: window).contains {
                $0.value("accessibilityIdentifier") as? String == "vocabulary.transferMenu"
            })
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `keyword sheets scroll long alias lists and leave enabled and save reachable`(style: InterfaceStyle) async throws {
        try await UI.withFixture { _ in
            var draft = AskKeywordDraft(adding: .prompt)
            draft.keyword = "fixture"
            draft.prompt = "Summarize {input}."
            draft.aliases = (0 ..< 12).map { "alias\($0)" }
            var saved: AskKeyword?
            let sheet = AskKeywordEditorSheet(draft: draft, keywords: [], workflows: [],
                                               onSave: { saved = $0 }, onCancel: {}).environment(\.interfaceStyle, style)
            try await UI.withWindow(sheet, width: 560, height: 500) { window, host in
                try await UI.wait { outerScroll(in: host) != nil }
                let scroll = try #require(outerScroll(in: host))
                try await UI.wait { scroll.hasVerticalScroller }
                #expect(scroll.hasVerticalScroller && scroll.verticalScroller != nil)
                scrollToBottom(scroll)
                host.layoutSubtreeIfNeeded()
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                let enabled = try element("ask.settings.keywords.sheet.enabled", in: host)
                #expect(bounds.contains(enabled.frame))
                try enabled.press()
                let save = try element("ask.settings.keywords.sheet.save", in: host)
                #expect(bounds.contains(save.frame))
                #expect(bounds.contains(try element("typeflux.sheet.cancel", in: host).frame))
                try save.press()
                #expect(saved?.aliases.count == 12 && saved?.enabled == false)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `MCP import scrolls long previews while keeping cancel and confirm visible`(style: InterfaceStyle) async throws {
        try await UI.withFixture { _ in
            let servers = (0 ..< 40).map { "\"fixture-\($0)\":{\"command\":\"fixture-tool\"}" }
            let json = "{\"mcpServers\":{\(servers.joined(separator: ","))}}"
            var imported: [MCPServerConfig] = []
            let sheet = MCPServerImportSheet(text: .constant(json), existingNames: [], cancel: {},
                                             confirm: { imported = $0 }).environment(\.interfaceStyle, style)
            try await UI.withWindow(sheet, width: 520, height: 400) { window, host in
                let editor = try #require(UI.nativeViews(in: host).compactMap { $0 as? NSTextView }
                    .first { $0.string == json })
                #expect(editor.alignment != .right)
                let outer = try #require(outerScroll(in: host))
                scrollToBottom(outer)
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                for identifier in ["typeflux.sheet.cancel", "typeflux.sheet.confirm"] {
                    #expect(bounds.contains(try element(identifier, in: host).frame))
                }
                try element("typeflux.sheet.confirm", in: host).press()
                #expect(imported.count == 40)
            }
        }
    }

    @Test(arguments: [MCPTransportType.stdio, .http])
    func `MCP editor keeps input placeholders inside fields`(transport: MCPTransportType) async throws {
        try await UI.withFixture { settings in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                                        initialSection: .agent,
                                        modelLibrary: AskModelLibrary(defaults: settings.defaults,
                                                                      automaticallyLoadsCatalog: false))
            model.beginAddMCPServer()
            model.mcpDraftTransportType = transport
            model.mcpDraftName = "Fixture MCP"
            model.mcpDraftStdioCommand = "/fixture/tool"
            model.mcpDraftHTTPURL = "https://example.invalid/mcp"
            try await UI.withWindow(MCPServerEditorView(viewModel: model, onClose: {}),
                                    width: 560, height: 600) { _, host in
                try await UI.wait { fields(in: host).contains { $0.stringValue == "Fixture MCP" } }
                for field in fields(in: host).filter(\.isEditable) { #expect(field.alignment != .right) }
                let name = try #require(fields(in: host).first { $0.stringValue == "Fixture MCP" })
                #expect(name.placeholderString == L("agent.mcp.namePlaceholder"))
                #expect(!fields(in: host).contains {
                    !$0.isEditable && $0.stringValue == L("agent.mcp.namePlaceholder")
                })
            }
        }
    }

    private func fields(in host: NSView) -> [NSTextField] {
        UI.nativeViews(in: host).compactMap { $0 as? NSTextField }
    }

    private func element(_ identifier: String, in host: NSView) throws -> UI.Element {
        try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == identifier })
    }

    private func outerScroll(in host: NSView) -> NSScrollView? {
        UI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first {
            guard let document = $0.documentView else { return false }
            return !(document is NSTextView) && document.bounds.height > $0.contentSize.height
        }
    }

    private func formScroll(in host: NSView) -> NSScrollView? {
        UI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.filter {
            $0.documentView != nil && !($0.documentView is NSTextView)
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private func scrollToBottom(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
