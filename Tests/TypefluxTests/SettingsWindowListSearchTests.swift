import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct SettingsWindowListSearchTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `memory search filters notes and adding clears the toolbar query`() async throws {
        try await UI.withFixture { _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = AskMemoryNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
            _ = try store.add("Prefers metric units", owner: "fixture")
            _ = try store.add("Prefers dark mode", owner: "fixture")
            let model = AskMemoryNotesSettingsModel()
            model.reload(from: store, owner: "fixture")
            let search = TypefluxSearchState()
            let query = Binding(get: { search.query }, set: { search.query = $0 })
            let windowView = TypefluxWindow(title: "Memory", search: search, searchPrompt: "Find a note") {
                Text("Agent")
            } detail: {
                MemoryNotesEditorView(model: model, store: store, owner: "fixture", query: query).padding()
            }
            try await TypefluxNavigationTestSupport.withWindow(windowView) { window, host in
                try await UI.wait { UI.contains("Prefers metric units", in: host) }
                search.query = "  METRIC  "
                try await UI.wait { !UI.contains("Prefers dark mode", in: host) }
                #expect(UI.contains("Prefers metric units", in: host))
                search.query = "no match"
                try await UI.wait { UI.contains(L("agent.memory.noMatch"), in: host) }
                try UI.button(L("agent.memory.add"), in: host).press()
                try await UI.wait { search.query.isEmpty && model.draft != nil }
                #expect(model.draft?.note == nil)
                #expect(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true)
            }
        }
    }

    @Test func `keyword search uses the window query and preserves category filtering`() async throws {
        try await UI.withFixture { settings in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workflows = AskWorkflowStore(settings: settings, root: directory)
            settings.askLauncherKeywords = AskPluginRegistry.defaultKeywords
            let search = TypefluxSearchState()
            let view = TypefluxWindow(title: "Keywords", search: search, searchPrompt: "Find a keyword") {
                Text("Launcher")
            } detail: {
                AskLauncherPluginSettingsView(settings: settings, workflows: workflows, initialFilter: .history,
                                              query: Binding(get: { search.query }, set: { search.query = $0 }))
            }
            try await TypefluxNavigationTestSupport.withWindow(view) { _, host in
                let row = "ask.settings.keywords.row.history"
                @MainActor func containsRow() -> Bool {
                    UI.elements(in: host).contains { $0.value("accessibilityIdentifier") as? String == row }
                }
                try await UI.wait { containsRow() }
                search.query = "unmatched"
                try await UI.wait { !containsRow() }
                search.query = ""
                try await UI.wait { containsRow() }
                #expect(!UI.elements(in: host).contains {
                    $0.value("accessibilityIdentifier") as? String == "ask.settings.keywords.row.fy"
                })
            }
        }
    }

    @Test func `settings footer preserves dismissal and compact sign in`() async throws {
        try await UI.withFixture { settings in
            var signIns = 0
            let footer = StudioSidebarFooter(defaults: settings.defaults, compact: false) { signIns += 1 }
            try await UI.withWindow(footer, width: 220, height: 300) { _, host in
                try await UI.wait { UI.contains("Typeflux Cloud", in: host) }
                @MainActor func signInCount() -> Int {
                    UI.elements(in: host).filter {
                        $0.role == NSAccessibility.Role.button.rawValue && $0.label == L("ask.cloudPromo.signIn")
                    }.count
                }
                #expect(signInCount() == 1)
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(signIns == 1)
                try UI.button(L("ask.cloudPromo.dismiss"), in: host).press()
                try await UI.wait { !UI.contains("Typeflux Cloud", in: host) }
                #expect(settings.defaults.double(forKey: AskCloudPromo.dismissedKey) > 0)
                #expect(signInCount() == 1)
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(signIns == 2)
            }
            settings.defaults.set(0, forKey: AskCloudPromo.dismissedKey)
            try await UI.withWindow(StudioSidebarFooter(defaults: settings.defaults, compact: true) {
                signIns += 1
            }, width: 220, height: 80) { _, host in
                #expect(!UI.contains("Typeflux Cloud", in: host))
                #expect(UI.contains(L("ask.local.identity"), in: host))
                try UI.button(L("ask.cloudPromo.signIn"), in: host).press()
                #expect(signIns == 3)
            }
            AuthState.shared.isLoggedIn = true
            try await UI.withWindow(StudioSidebarFooter(defaults: settings.defaults, compact: true) {},
                                    width: 220, height: 80) { _, host in
                #expect(!UI.contains("Typeflux Cloud", in: host))
                #expect(!UI.contains(L("ask.cloudPromo.signIn"), in: host))
                #expect(UI.contains(L("sidebar.appName"), in: host))
            }
        }
    }

    @Test func `workflow search matches descriptions and keywords`() async throws {
        try await UI.withFixture { _ in
            let fixture = try AskWorkflowFixture()
            try fixture.write("alpha", manifest: AskWorkflowFixture.inline("alpha", keyword: "alphakey", script: "echo",
                                                                           extra: [
                                                                               "name": "Alpha Workflow",
                                                                               "description": "Exports a greeting"
                                                                           ]))
            try fixture.write("beta", manifest: AskWorkflowFixture.inline("beta", script: "echo",
                                                                          extra: [
                                                                              "name": "Beta Workflow",
                                                                              "description": "Metric report"
                                                                          ]))
            fixture.store.reload()
            #expect(fixture.store.workflows.count == 2)
            #expect(fixture.store.workflows.allSatisfy { $0.manifest != nil })
            let search = TypefluxSearchState()
            let view = TypefluxWindow(title: "Workflows", search: search, searchPrompt: "Find a workflow") {
                Text("Launcher")
            } detail: {
                AskWorkflowSettingsView(store: fixture.store, log: AskWorkflowLog(), settings: fixture.settings)
            }
            try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
                @MainActor func containsWorkflow(_ id: String) -> Bool {
                    UI.elements(in: window).contains {
                        $0.role == NSAccessibility.Role.button.rawValue
                            && $0.label.hasSuffix(id == "alpha" ? "Alpha Workflow" : "Beta Workflow")
                    }
                }
                try await UI.wait { containsWorkflow("alpha") }
                search.query = "metric"
                try await UI.wait { !containsWorkflow("alpha") }
                #expect(containsWorkflow("beta"))
                search.query = "alphakey"
                try await UI.wait { containsWorkflow("alpha") }
                #expect(!containsWorkflow("beta"))
                search.query = "unmatched"
                try await UI.wait { UI.contains(L("personas.redesign.noResults", "unmatched"), in: window) }
            }
        }
    }
}
