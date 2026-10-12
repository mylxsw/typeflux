import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct SettingsWindowNavigationTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `all pages have native toolbar titles and keep sidebar order`() async throws {
        try await UI.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(previousPolicy) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let controller = SettingsWindowController()
            controller.modelLibrary = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory))
            let window = try #require(controller.window)
            let model = try #require(controller.viewModel)
            defer { window.close() }
            let host = try #require(window.contentView)
            for section in StudioSection.allCases {
                model.navigate(to: section)
                try await UI.wait { window.title.hasPrefix(section.heading) }
                #expect(!UI.elements(in: host).contains {
                    $0.value("accessibilityIdentifier") as? String == "studio.page.title"
                })
            }
            for section in StudioSection.sidebarUpperCases {
                try await UI.wait { UI.contains(section.sidebarTitle, in: window) }
                try UI.button(section.sidebarTitle, in: window).press()
                try await UI.wait { model.currentSection.sidebarSection == section }
            }
            #expect(StudioSection.sidebarUpperCases == [.home, .models, .agent, .launcher, .settings])
            controller.show(settingsStore: settings, historyStore: FileHistoryStore(baseDir: directory),
                            initialSection: .vocabulary)
            #expect(controller.window === window)
            try await UI.wait { window.title == StudioSection.vocabulary.heading }
            #expect(window.toolbarStyle == .unified && window.titleVisibility == .visible)
            try await type("toolbar-position", in: window)
            let search = try #require(searchItem(window))
            try await UI.wait {
                search.searchField.convert(search.searchField.bounds, to: nil).maxX > window.frame.width - 60
            }
        }
    }

    @Test func `vocabulary personas and models use the native search and reset on navigation`() async throws {
        try await UI.withFixture { settings in
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(previousPolicy) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let controller = SettingsWindowController()
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
            model.selectModelPageTab(.language)
            try await type("OpenAI", in: window)
            try await UI.wait { model.modelSearchQuery == "OpenAI" }
            #expect(model.searchQuery.isEmpty)
            model.selectModelPageTab(.speech)
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
                    try await open(pane.title, in: host)
                    try await UI.wait { window.title.contains(pane.title) }
                    try await type("no-results-346", in: window)
                    let item = try #require(searchItem(window))
                    #expect(item.searchField.stringValue == "no-results-346")
                    #expect(!UI.elements(in: host).contains { $0.role == NSAccessibility.Role.textField.rawValue })
                    if pane == .skills {
                        try await UI.wait { UI.contains(L("agent.skills.noMatch"), in: host) }
                    }
                    if pane == .mcpServers {
                        try await UI.wait { UI.contains(L("personas.redesign.noResults", "no-results-346"), in: host) }
                        #expect(!UI.contains("Alpha Server", in: host) && !UI.contains("Beta Server", in: host))
                    }
                    try TypefluxNavigationTestSupport.sendKey(53, to: window)
                    try await UI.wait { item.searchField.stringValue.isEmpty }
                    try TypefluxNavigationTestSupport.sendKey(53, to: window)
                    try await UI.wait { item.searchField.currentEditor() == nil }
                }
                model.navigate(to: .launcher)
                for pane in [LauncherSettingsPane.keywords, .workflows] {
                    try await open(pane.title, in: host)
                    try await UI.wait { window.title.contains(pane.title) }
                    try await type("no-results-346", in: window)
                    #expect(searchItem(window)?.searchField.stringValue == "no-results-346")
                    if pane == .keywords {
                        #expect(!UI.elements(in: host).contains {
                            ($0.value("accessibilityIdentifier") as? String ?? "")
                                .hasPrefix("ask.settings.keywords.row.")
                        })
                    }
                }
                try await open(LauncherSettingsPane.basics.title, in: host)
                try await UI.wait { searchItem(window) == nil }
            }
        }
    }

    private func open(_ title: String, in host: NSView) async throws {
        try await UI.wait {
            UI.elements(in: host)
                .contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label.hasPrefix(title) }
        }
        let button = try #require(UI.elements(in: host).first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label.hasPrefix(title)
        })
        try button.press()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func searchItem(_ window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    private func type(_ query: String, in window: NSWindow) async throws {
        try await UI.wait { searchItem(window) != nil }
        try await Task.sleep(for: .milliseconds(50))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
        let item = try #require(searchItem(window))
        try await UI.wait { item.searchField.currentEditor() != nil }
        let editor = try #require(item.searchField.currentEditor() as? NSTextView)
        editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        item.searchField.validateEditing()
        item.searchField.sendAction(item.searchField.action, to: item.searchField.target)
        try await UI.wait { item.searchField.stringValue == query }
        try await Task.sleep(for: .milliseconds(80))
    }
}
