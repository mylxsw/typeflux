import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct SettingsWindowNavigationTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `pane row identifiers select nested cells despite status labels`() async throws {
        try await UI.withFixture { _ in
            var selection = AgentSettingsPane.overview
            let list = SettingsPaneList(sections: AgentSettingsPane.sections,
                                        selection: Binding(get: { selection }, set: { selection = $0 }),
                                        status: { _ in AgentCapabilityStatus.mcpStatus(for: []) })
            try await UI.withWindow(list, width: 260, height: 640) { window, host in
                for pane in [AgentSettingsPane.skills, .memory, .mcpServers, .overview] {
                    try await selectPane(pane, in: host)
                    try await wait("Pane binding selected \(pane.id)", in: window) { selection == pane }
                    let (table, row) = try #require(paneRow(pane, in: host))
                    let identifier = "settings.pane.\(pane.id)"
                    #expect(paneCellElements(in: table, row: row).contains {
                        $0.value("accessibilityIdentifier") as? String == identifier
                    })
                }
            }
        }
    }

    @Test func `all pages have native toolbar titles and keep sidebar order`() async throws {
        try await UI.withFixture { settings in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let dockVisibility = DockVisibilityController(app: TypefluxTestActivationPolicyController())
            let controller = SettingsWindowController(dockVisibility: dockVisibility)
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory))
            let window = try #require(controller.window)
            let model = try #require(controller.viewModel)
            defer { window.close() }
            let host = try #require(window.contentView)
            for section in StudioSection.allCases {
                model.navigate(to: section)
                let title = section == .models ? section.title : section.heading
                do { try await UI.wait { window.title.hasPrefix(title) } }
                catch {
                    Issue.record("Expected title \(title) for \(section.rawValue); found \(window.title)")
                    throw error
                }
                #expect(!UI.elements(in: host).contains {
                    $0.value("accessibilityIdentifier") as? String == "studio.page.title"
                })
            }
            // AppKit can collapse the split column while destinations change their preferred widths.
            // Exercise the native disclosure before checking navigation rows.
            if UI.contains("Show Sidebar", in: window) {
                try UI.button("Show Sidebar", in: window).press()
            }
            for section in StudioSection.sidebarUpperCases {
                do { try await UI.wait { UI.contains(section.sidebarTitle, in: window) } }
                catch {
                    Issue.record("Missing sidebar label \(section.sidebarTitle)")
                    throw error
                }
                try UI.button(section.sidebarTitle, in: window).press()
                do { try await UI.wait { model.currentSection.sidebarSection == section } }
                catch {
                    Issue.record("Sidebar \(section.rawValue) did not navigate; found \(model.currentSection.rawValue)")
                    throw error
                }
            }
            #expect(StudioSection.sidebarUpperCases == [.home, .history, .vocabulary, .personas, .models, .agent, .launcher, .settings, .account])
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                            initialSection: .vocabulary)
            #expect(controller.window === window)
            try await UI.wait { window.title == StudioSection.vocabulary.heading }
            #expect(window.toolbarStyle == .unified && window.titleVisibility == .hidden)
            try await type("toolbar-position", in: window)
            let search = try #require(searchItem(window))
            try await UI.wait {
                search.searchField.convert(search.searchField.bounds, to: nil).maxX > window.frame.width - 60
            }
        }
    }

    @Test func `vocabulary personas and models use the native search and reset on navigation`() async throws {
        try await UI.withFixture { settings in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let dockVisibility = DockVisibilityController(app: TypefluxTestActivationPolicyController())
            let controller = SettingsWindowController(dockVisibility: dockVisibility)
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                            initialSection: .vocabulary)
            let window = try #require(controller.window)
            let model = try #require(controller.viewModel)
            defer { window.close() }
            model.addVocabularyTerm("Toolbar Alpha")
            model.addVocabularyTerm("Toolbar Beta")
            try await type("Alpha", in: window)
            try await UI.wait { model.searchQuery == "Alpha" }
            #expect(model.filteredVocabularyEntries.map(\.term) == ["Toolbar Alpha"])
            try TypefluxNavigationTestSupport.sendKey(53, to: window)
            try await UI.wait { model.searchQuery.isEmpty }
            #expect(searchItem(window)?.searchField.currentEditor() != nil)
            try TypefluxNavigationTestSupport.sendKey(53, to: window)
            try await UI.wait { searchItem(window)?.searchField.currentEditor() == nil }

            model.navigate(to: .personas)
            try await UI.wait { window.title == StudioSection.personas.heading }
            try await Task.sleep(for: .milliseconds(100))
            try await type("unmatched-persona", in: window)
            try await UI.wait { model.searchQuery == "unmatched-persona" }
            #expect(model.filteredPersonas.isEmpty)
            model.navigate(to: .history)
            try await UI.wait { window.title == StudioSection.history.heading }
            try await Task.sleep(for: .milliseconds(100))
            try await UI.wait { model.searchQuery.isEmpty && searchItem(window)?.searchField.stringValue == "" }
            try await type("history-query", in: window)
            try await UI.wait { model.searchQuery == "history-query" }

            model.navigate(to: .models)
            model.selectModelPageTab(.providers)
            try await type("OpenAI", in: window)
            try await UI.wait { model.modelSearchQuery == "OpenAI" }
            #expect(model.searchQuery.isEmpty)
            model.selectModelPageTab(.providers)
            try await UI.wait { model.modelSearchQuery.isEmpty && searchItem(window)?.searchField.stringValue == "" }
            model.selectModelPageTab(.scenes)
            try await UI.wait { searchItem(window) == nil }
            try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
            #expect(searchItem(window) == nil)
        }
    }

    @Test func `agent and launcher lists share toolbar search without inline fields`() async throws {
        try await UI.withFixture { settings in
            settings.mcpServers = [
                MCPServerConfig(
                    name: "Alpha Server",
                    transport: .stdio(.init(command: "/fixture-alpha")),
                    enabled: false
                ),
                MCPServerConfig(
                    name: "Beta Server",
                    transport: .http(.init(url: "https://example.invalid")),
                    enabled: false
                )
            ]
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                                        initialSection: .agent, modelLibrary: library)
            try await TypefluxNavigationTestSupport.withWindow(StudioView(viewModel: model),
                                                               size: NSSize(width: 1300, height: 800)) { window, host in
                for pane in [AgentSettingsPane.skills, .memory, .mcpServers] {
                    try await selectPane(pane, in: host)
                    try await wait("Agent pane title: \(pane.title)", in: window) { window.title.contains(pane.title) }
                    try await type("no-results-346", in: window)
                    let item = try #require(searchItem(window))
                    #expect(item.searchField.stringValue == "no-results-346")
                    #expect(!UI.elements(in: host).contains { $0.role == NSAccessibility.Role.textField.rawValue })
                    if pane == .skills {
                        try await wait("Skills filtered empty state", in: window) {
                            UI.contains(L("agent.skills.noMatch"), in: host)
                        }
                    }
                    if pane == .mcpServers {
                        try await wait("MCP servers filtered empty state", in: window) {
                            UI.contains(L("personas.redesign.noResults", "no-results-346"), in: host)
                        }
                        #expect(!UI.contains("Alpha Server", in: host) && !UI.contains("Beta Server", in: host))
                    }
                    try TypefluxNavigationTestSupport.sendKey(53, to: window)
                    try await wait("Clear search with Escape in \(pane.title)", in: window) {
                        item.searchField.stringValue.isEmpty
                    }
                    try TypefluxNavigationTestSupport.sendKey(53, to: window)
                    try await wait("End search editing with Escape in \(pane.title)", in: window) {
                        item.searchField.currentEditor() == nil
                    }
                }
                model.navigate(to: .launcher)
                for pane in [LauncherSettingsPane.keywords, .workflows] {
                    try await selectPane(pane, in: host)
                    try await wait("Launcher pane title: \(pane.title)", in: window) { window.title.contains(pane.title) }
                    try await type("no-results-346", in: window)
                    #expect(searchItem(window)?.searchField.stringValue == "no-results-346")
                    if pane == .keywords {
                        #expect(!UI.elements(in: host).contains {
                            ($0.value("accessibilityIdentifier") as? String ?? "")
                                .hasPrefix("ask.settings.keywords.row.")
                        })
                    }
                }
                try await selectPane(LauncherSettingsPane.basics, in: host)
                try await wait("Launcher basics removes toolbar search", in: window) { searchItem(window) == nil }
            }
        }
    }

    private func selectPane<Pane: SettingsPaneItem & CaseIterable>(_ pane: Pane, in host: NSView) async throws {
        let window = try #require(host.window)
        try await wait("Native pane list row: \(pane.title)", in: window) {
            self.paneRow(pane, in: host) != nil
        }
        let (table, row) = try #require(paneRow(pane, in: host))
        // SettingsPaneList is List(selection:), so select its native row rather than waiting for a Button.
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        #expect(table.selectedRowIndexes == IndexSet(integer: row))
    }

    private func paneRow<Pane: SettingsPaneItem & CaseIterable>(_ pane: Pane, in host: NSView) -> (NSTableView, Int)? {
        host.layoutSubtreeIfNeeded()
        let identifier = "settings.pane.\(pane.id)"
        let titles = Set(Pane.allCases.map(\.title))
        for table in UI.nativeViews(in: host).compactMap({ $0 as? NSTableView }) {
            guard table.window === host.window, !table.isHiddenOrHasHiddenAncestor else { continue }
            var rows: [String: Int] = [:]
            for index in 0 ..< table.numberOfRows {
                let elements = paneCellElements(in: table, row: index)
                if elements.contains(where: { $0.value("accessibilityIdentifier") as? String == identifier }) {
                    return (table, index)
                }
                for title in titles where elements.contains(where: {
                    let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text == title || label == title || label.hasPrefix(title + ", ")
                }) {
                    rows[title] = index
                }
            }
            // Recognize the complete pane roster, keeping the app sidebar and content lists out of scope.
            if rows.count == titles.count, let index = rows[pane.title] { return (table, index) }
        }
        return nil
    }

    private func paneCellElements(in table: NSTableView, row: Int) -> [UI.Element] {
        // AppKit row views need not expose their hosting cells as AX children. Read the cells and
        // their native subviews explicitly rather than relying on the row container's label.
        var roots: [Any] = (0 ..< table.numberOfColumns).compactMap {
            table.view(atColumn: $0, row: row, makeIfNecessary: true)
        }
        if let view = table.rowView(atRow: row, makeIfNecessary: true) { roots.append(view) }
        let accessibilityRows = UI.Element(object: table, window: table.window)
            .value("accessibilityRows") as? [Any] ?? []
        if accessibilityRows.count == table.numberOfRows { roots.append(accessibilityRows[row]) }
        var seen = Set<ObjectIdentifier>()
        return roots.flatMap { root -> [UI.Element] in
            let native = (root as? NSView).map { UI.nativeViews(in: $0) } ?? []
            return (UI.elements(in: root) + native.flatMap { UI.elements(in: $0) }).filter {
                seen.insert(ObjectIdentifier($0.object)).inserted
            }
        }
    }

    private func wait(_ description: String, in window: NSWindow, _ condition: () -> Bool) async throws {
        do {
            try await UI.wait(description, condition)
        } catch {
            let field = searchItem(window)?.searchField
            let rows = window.contentView.map { host in
                UI.nativeViews(in: host).compactMap { $0 as? NSTableView }.map(\.numberOfRows)
            } ?? []
            Issue.record("""
                \(description): title=\(window.title), search=\(field?.stringValue ?? "<absent>"), \
                editor=\(field?.currentEditor() != nil), tableRows=\(rows)
                """)
            throw error
        }
    }

    private func searchItem(_ window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    private func type(_ query: String, in window: NSWindow) async throws {
        try await wait("Native toolbar search item", in: window) { searchItem(window) != nil }
        try await Task.sleep(for: .milliseconds(50))
        try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
        let item = try #require(searchItem(window))
        try await wait("Owned search field editor", in: window) { item.searchField.currentEditor() != nil }
        let editor = try #require(item.searchField.currentEditor() as? NSTextView)
        editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        item.searchField.validateEditing()
        item.searchField.sendAction(item.searchField.action, to: item.searchField.target)
        try await wait("Toolbar search query: \(query)", in: window) { item.searchField.stringValue == query }
        try await Task.sleep(for: .milliseconds(80))
    }
}
