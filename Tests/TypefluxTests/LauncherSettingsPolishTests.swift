import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct LauncherSettingsPolishTests {
    private func render(_ view: some View, size: NSSize, name: String, light: Bool = false,
                        check: (NSWindow) async throws -> Void = { _ in }) async throws {
        _ = NSApplication.shared
        // SwiftUI publishes its native accessibility nodes when this process-wide flag is enabled.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(StudioTheme.windowBackground))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(180))
        hosting.layoutSubtreeIfNeeded()
        try await check(window)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }

    private func fixture() throws -> AskWorkflowFixture {
        let fixture = try AskWorkflowFixture()
        for (id, keywords) in [("encoding", ["url", "b64", "rate", "abcdefghijkl"]), ("off", ["off"]),
                               ("untrusted", ["new"]), ("modified", ["changed"])] {
            try fixture.write(id, manifest: AskWorkflowFixture.inline(id, script: "echo", extra: [
                "name": id == "encoding" ? "URL / Base64 encoding with a long workflow name" : id.capitalized,
                "description": "Encode and decode text. This deliberately long description must remain separate from all controls and metadata, even when it fills more than two lines in a narrow pane.",
                "keywords": keywords.map { ["keyword": $0] }
            ]))
        }
        try fixture.write(
            "broken",
            manifest: ["id": "broken", "name": "Broken workflow", "keywords": [["keyword": "fix"]],
                       "command": ["runtime": "python3", "script": "missing.py"]]
        )
        fixture.store.reload()
        for id in ["encoding", "off", "modified"] {
            fixture.store.trust(id)
        }
        fixture.store.setEnabled("off", false)
        try Data("changed".utf8).write(to: fixture.root.appendingPathComponent("modified/notes.md"))
        fixture.store.reload()
        return fixture
    }

    @Test func `pages render at default and minimum window sizes`() async throws {
        let previous = AppLocalization.shared.language
        let snapshots = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_SNAPSHOTS"] != nil
        if snapshots {
            AppLocalization.shared.setLanguage(.simplifiedChinese)
        }
        defer {
            if snapshots {
                AppLocalization.shared.setLanguage(previous)
            }
        }
        let fixture = try fixture()
        fixture.settings.appLanguage = AppLocalization.shared.language
        let model = StudioViewModel(settingsStore: fixture.settings,
                                    historyStore: SQLiteHistoryStore(baseDir: fixture.home
                                        .appendingPathComponent("History")),
                                    initialSection: .launcher)
        #expect(StudioSection.launcher.subheading == nil)
        for height in [StudioTheme.Layout.settingsWindowHeight, StudioTheme.Layout.settingsWindowMinHeight] {
            for light in [false, true] {
                for pane in LauncherSettingsPane.allCases {
                    try await render(StudioView(viewModel: model, launcherPane: pane),
                                     size: NSSize(width: 1100, height: height),
                                     name: "page-\(pane.rawValue)-\(Int(height))-\(light ? "light" : "dark")",
                                     light: light) { window in
                        if pane == .basics {
                            #expect(find("launcher.settings.numberConversions", in: window) != nil)
                            #expect(!SettingsBehaviorTestSupport.contains(
                                L("ask.settings.quick.numberConversions.subtitle"), in: window
                            ))
                        } else if pane == .search {
                            #expect(SettingsBehaviorTestSupport.contains(L("launcher.search.fuzzy"), in: window))
                            #expect(!SettingsBehaviorTestSupport.contains(L("launcher.search.mode"), in: window))
                        }
                    }
                }
            }
        }
        // The full page uses the shared workflow store. Render populated rows from our isolated fixture as well.
        for light in [false, true] {
            try await render(ScrollView {
                LauncherSettingsView(settings: fixture.settings, pane: .keywords, workflows: fixture.store).padding(24)
            }, size: NSSize(width: 800, height: 1000), name: "keyword-list-\(light ? "light" : "dark")", light: light)
            try await render(ScrollView {
                LauncherSettingsView(settings: fixture.settings, pane: .workflows, workflows: fixture.store).padding(24)
            }, size: NSSize(width: 574, height: 900), name: "workflow-states-\(light ? "light" : "dark")", light: light)
            for tab in LauncherSearchSettingsView.Tab.allCases {
                try await render(ScrollView {
                    LauncherSearchSettingsView(settings: fixture.settings, index: AskTestFileIndex(), tab: tab)
                        .padding(24)
                }, size: NSSize(width: 574, height: 800), name: "search-\(tab.rawValue)-\(light ? "light" : "dark")",
                light: light)
            }
        }
    }

    @Test func `keywords wrap whole chips and actions remain reachable`() async throws {
        let fixture = try fixture()
        let workflow = try #require(fixture.store.workflow("encoding"))
        let summary = AskWorkflowSummary(workflow)
        var edited = false
        try await render(AskWorkflowSettingsRow(symbol: workflow.symbol, summary: summary, edit: { edited = true }) {
            Toggle("Enabled", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("test.enabled")
        }, size: NSSize(width: 320, height: 280), name: "workflow-row-narrow") { window in
            let edit = try element("ask.workflow.edit", in: window)
            let toggle = try element("test.enabled", in: window)
            #expect(!edit.frame.intersects(toggle.frame), "the title never overlaps the controls")
            #expect(window.convertToScreen(window.contentView!.bounds).contains(toggle.frame))
            try click(edit, in: window)
            #expect(edited, "clicking the workflow name reaches its editor action")
        }
        try await render(AgentFlowLayout(spacing: 6) {
            ForEach(["url", "b64", "rate", "abcdefghijkl"], id: \.self) { word in
                AskKeywordListChip(keyword: word).accessibilityIdentifier("chip." + word)
            }
        }.frame(width: 160, alignment: .leading), size: NSSize(width: 160, height: 100),
        name: "keyword-chips") { window in
            let chips = try ["url", "b64", "rate", "abcdefghijkl"].map { try element("chip." + $0, in: window).frame }
            #expect(chips.allSatisfy { $0.height <= 23 }, "every chip stays on one line")
            #expect(chips.last!.minY < chips.first!.minY, "an entire long chip wraps onto the next line")
            #expect(chips.allSatisfy { $0.maxX <= window.convertToScreen(window.contentView!.bounds).maxX + 1 })
        }
    }

    @Test func `trust and repair actions stay visible beside diagnostics`() async throws {
        let fixture = try fixture()
        for id in ["untrusted", "modified", "broken"] {
            let workflow = try #require(fixture.store.workflow(id))
            let summary = AskWorkflowSummary(workflow)
            var invoked = false
            let row = AskWorkflowSettingsRow(symbol: workflow.symbol, summary: summary, edit: {},
                                             review: summary.needsTrust ? { invoked = true } : nil,
                                             fix: id == "broken" ? { invoked = true } : nil, controls: { EmptyView() })
            try await render(row, size: NSSize(width: 400, height: 320), name: "workflow-\(id)") { window in
                let action = try element(id == "broken" ? "ask.workflow.fix" : "ask.workflow.review", in: window)
                #expect(action.frame.width > 0 && action.frame.height > 0)
                try click(action, in: window)
                #expect(invoked)
            }
        }
    }

    @Test func `workflow header actions fit and switches preserve trust requirements`() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try fixture()
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.shared.setLanguage(language)
            for width in [400.0, 574.0, 800.0] {
                try await render(ScrollView {
                    LauncherSettingsView(settings: fixture.settings, pane: .workflows, workflows: fixture.store)
                }, size: NSSize(width: width, height: 1100),
                name: "workflow-header-\(language.rawValue)-\(Int(width))") { window in
                    let actions = try ["ask.workflow.gallery", "ask.workflow.manage", "ask.workflow.new"]
                        .map { try element($0, in: window).frame }
                    let bounds = window.convertToScreen(window.contentView!.bounds)
                    for action in actions {
                        #expect(action.minX >= bounds.minX - 1 && action.maxX <= bounds.maxX + 1)
                        #expect(action.height >= SettingsControlMetrics.height)
                    }
                    #expect(actions[0].maxX < actions[1].minX && actions[1].maxX < actions[2].minX)
                    #expect(abs(actions[0].midY - actions[2].midY) < 1)
                    #expect(find("ellipsis", in: window) == nil, "no persistent more buttons compete with the switches")
                    let pending = try element("ask.workflow.enabled.untrusted", in: window)
                    #expect(pending.isOn == false && pending.enabled == false)
                    let modified = try element("ask.workflow.enabled.modified", in: window)
                    #expect(modified.isOn == false && modified.enabled == false)
                    #expect(try element("ask.workflow.enabled.encoding", in: window).isOn == true)
                }
            }
        }
        try await render(LauncherSettingsView(settings: fixture.settings, pane: .workflows, workflows: fixture.store),
                         size: NSSize(width: 800, height: 1100), name: "workflow-switch") { window in
            try click(element("ask.workflow.enabled.encoding", in: window), in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!fixture.store.isEnabled("encoding"))
            try click(element("ask.workflow.enabled.encoding", in: window), in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.store.isEnabled("encoding"))
        }
    }

    @Test func `workflow rows only emphasize problems and keep failure details reachable`() async throws {
        let fixture = try fixture()
        let workflow = try #require(fixture.store.workflow("encoding"))
        for exitCode in [Int32(0), Int32(2)] {
            let entry = AskWorkflowLog.Entry(workflowID: workflow.id, keyword: "url", date: Date(), duration: 0.1,
                                             exitCode: exitCode, timedOut: false, stderr: "Example failure details")
            let summary = AskWorkflowSummary(workflow, lastRun: entry)
            var inspected = false
            try await render(AskWorkflowSettingsRow(symbol: workflow.symbol, summary: summary, edit: {},
                                                    viewLastRun: { inspected = true }, controls: { EmptyView() }),
                             size: NSSize(width: 574, height: 200), name: "workflow-run-\(exitCode)") { window in
                #expect(find("ask.workflow.status", in: window) == nil)
                #expect((find("ask.workflow.runNotice", in: window) != nil) == (exitCode != 0))
                if exitCode != 0 {
                    try click(element("ask.workflow.runDetails", in: window), in: window)
                    #expect(inspected)
                } else {
                    #expect(find("ask.workflow.runDetails", in: window) == nil)
                }
            }
            if exitCode != 0 {
                try await render(AskWorkflowRunDetails(title: summary.title, entry: entry),
                                 size: NSSize(width: 560, height: 420), name: "workflow-run-details")
            }
        }
    }

    @Test func `shared tabs render counts and write through their binding`() async throws {
        final class Selection { var value: Int? = nil }
        let selection = Selection()
        for compact in [false, true] {
            selection.value = nil
            try await render(StudioSegmentedControl(options: [("All", nil), ("Apps", 1)],
                                                    selection: Binding(
                                                        get: { selection.value },
                                                        set: { selection.value = $0 }
                                                    ),
                                                    size: compact ? .compact : .regular, counts: [nil: 5, 1: 2],
                                                    optionIdentifier: { "tab.\($0 ?? 0)" }),
                             size: NSSize(width: 220, height: 50), name: "shared-tabs-\(compact)") { window in
                let app = try element("tab.1", in: window)
                #expect(app.frame.height == (compact ? 22 : 26))
                try click(app, in: window)
                #expect(selection.value == 1)
            }
        }
    }

    @Test func `keyword toolbar stays inside the pane with the add action on the right`() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try fixture()
        for language in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.shared.setLanguage(language)
            for width in [400.0, 574.0, 800.0] {
                for light in [false, true] {
                    try await render(AskLauncherPluginSettingsView(settings: fixture.settings,
                                                                   workflows: fixture.store,
                                                                   initialFilter: .history),
                                     size: NSSize(width: width, height: 300),
                                     name: "keyword-toolbar-\(language.rawValue)-\(Int(width))-\(light ? "light" : "dark")",
                                     light: light) { window in
                        let filter = try element("ask.settings.keywords.filter", in: window).frame
                        let search = try element("ask.settings.keywords.search", in: window).frame
                        let add = try element("ask.settings.keywords.add", in: window).frame
                        let bounds = window.convertToScreen(window.contentView!.bounds)
                        for frame in [filter, search, add] {
                            #expect(frame.width > 0 && frame.height > 0)
                            #expect(frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1)
                        }
                        #expect(filter.width <= 156)
                        #expect(!filter.intersects(search) && !filter.intersects(add))
                        #expect(search.maxX < add.minX)
                        #expect(abs(search.midY - add.midY) < 1)
                        #expect(abs(add.maxX - bounds.maxX) < 1, "the add action stays at the trailing edge")
                        #expect(find("ask.settings.keywords.row.history", in: window) != nil)
                        #expect(find("ask.settings.keywords.row.fy", in: window) == nil)
                    }
                }
            }
        }
    }

    @Test func `every keyword sheet renders without the repeated heading hint`() async throws {
        let fixture = try fixture()
        for light in [false, true] {
            for kind in AskKeywordKind.editableKinds {
                for isNew in [false, true] {
                    let keyword = try #require(AskPluginRegistry.defaultKeywords
                        .first { AskKeywordKind(pluginID: $0.pluginID) == kind })
                    let draft = isNew ? AskKeywordDraft(adding: kind) : AskKeywordDraft(editing: keyword)
                    try await render(AskKeywordEditorSheet(draft: draft, keywords: AskPluginRegistry.defaultKeywords,
                                                           workflows: [], onSave: { _ in }, onCancel: {}), size: NSSize(
                                         width: 560,
                                         height: 620
                                     ),
                                     name: "sheet-\(kind.rawValue)-\(isNew)-\(light ? "light" : "dark")", light: light)
                }
            }
        }
        try await render(AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store,
                                                       initialQuery: "url"), size: NSSize(width: 800, height: 500),
                         name: "keywords-no-workflow") { window in
            #expect(find("ask.settings.keywords.row.url", in: window) == nil)
            #expect(find("ask.settings.keywords.filter.workflow", in: window) == nil)
        }
    }

    @Test func `keyword sections collapse and persist while systems start folded`() async throws {
        let fixture = try fixture()
        try await render(ScrollView {
            AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store)
        }, size: NSSize(width: 700, height: 1600), name: "keyword-sections") { window in
            for section in AskKeywordSection.allCases {
                #expect(find("ask.settings.keywords.section." + section.rawValue, in: window) != nil)
            }
            #expect(find("ask.settings.keywords.row.fy", in: window) != nil)
            #expect(find("ask.settings.keywords.row." + AskSystemCommand.toggleBluetooth.defaultKeyword, in: window) ==
                nil)
        }
        try await render(ScrollView {
            AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store, initialFilter: .system)
        }, size: NSSize(width: 700, height: 600), name: "keyword-system-expanded") { window in
            try click(element("ask.settings.keywords.section.system", in: window), in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(find("ask.settings.keywords.row." + AskSystemCommand.toggleBluetooth.defaultKeyword, in: window) !=
                nil)
            #expect(fixture.settings.defaults.stringArray(forKey: "ask.keywordCollapsedSections") == [])
        }
        try await render(
            AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store, initialFilter: .web),
            size: NSSize(width: 700, height: 600),
            name: "keyword-search-collapsed"
        ) { window in
            try click(element("ask.settings.keywords.section.search", in: window), in: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(find("ask.settings.keywords.row.g", in: window) == nil)
            #expect(fixture.settings.defaults.stringArray(forKey: "ask.keywordCollapsedSections") == ["search"])
        }
        try await render(ScrollView {
            AskLauncherPluginSettingsView(settings: fixture.settings, workflows: fixture.store, initialFilter: .system)
        }, size: NSSize(width: 700, height: 600), name: "keyword-sections-restored") { window in
            #expect(find("ask.settings.keywords.row." + AskSystemCommand.toggleBluetooth.defaultKeyword, in: window) !=
                nil)
        }
    }

    @Test func `keyword rows wrap long aliases within narrow and wide panes`() async throws {
        let entry = AskKeyword(keyword: "f", pluginID: AskFileSearchPlugin.id,
                               aliases: [
                                   "filesearch",
                                   "searchfilesandfolders",
                                   "文件搜索",
                                   String(repeating: "w", count: 48)
                               ])
        let row = AskKeywordListPresentation.row(entry, kind: .files, interface: .english, secondLanguage: "en")
        for width in [320.0, 574.0, 900.0] {
            try await render(ModelSurface { AskKeywordRowView(row: row, toggle: {}, open: {}) },
                             size: NSSize(width: width, height: 180),
                             name: "keyword-alias-row-\(Int(width))") { window in
                let edit = try element("ask.settings.keywords.edit.f", in: window).frame
                let bounds = window.convertToScreen(window.contentView!.bounds)
                #expect(edit.minX >= bounds.minX && edit.maxX <= bounds.maxX)
                #expect(edit.height < bounds.height)
            }
        }
    }

    private struct Element {
        let object: NSObject
        var frame: NSRect {
            (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        }

        var children: [Any] {
            value("accessibilityChildren") as? [Any] ?? []
        }

        var identifier: String? {
            value("accessibilityIdentifier") as? String
        }

        var isOn: Bool? { (value("accessibilityValue") as? NSNumber)?.boolValue }

        var enabled: Bool? { value("isAccessibilityEnabled") as? Bool }

        private func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
    }

    private func find(_ id: String, in window: NSWindow) -> Element? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> Element? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = Element(object: object)
            if element.identifier == id {
                return element
            }
            for child in element.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func element(_ id: String, in window: NSWindow) throws -> Element {
        try #require(find(id, in: window), "Missing accessibility element: \(id)")
    }

    private func click(_ element: Element, in window: NSWindow) throws {
        let frame = window.convertFromScreen(element.frame)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY),
                                                        modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1,
                                                        pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }
}
