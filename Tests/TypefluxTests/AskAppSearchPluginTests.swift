import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("App-only keyword", .exclusiveUIState)
@MainActor
struct AskAppSearchPluginTests {
    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        .init(text: text, origin: origin, keyword: AskAppSearchPlugin.keywords[0], options: [:],
              interfaceLanguage: .english)
    }

    @Test func registersAndMigratesForExistingSettings() {
        #expect(AskPluginRegistry.pluginIDs.contains(AskAppSearchPlugin.id))
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskAppSearchPlugin.id }
        let migrated = AskPluginRegistry.keywords(saved: [], known: known)
        #expect(migrated.contains { $0.pluginID == AskAppSearchPlugin.id && $0.contains("app") })
        guard case let .active(keyword, argument) = AskKeywordMatcher.match("app Safari", keywords: migrated) else {
            Issue.record("The app keyword did not activate")
            return
        }
        #expect(keyword.pluginID == AskAppSearchPlugin.id && argument == "Safari")
        #expect(AskPluginRegistry.keywords(saved: [], known: AskPluginRegistry.coveredGroups).isEmpty)
        #expect(!AskPluginRegistry.keywords(saved: [], known: known, reserved: ["app"]).contains { $0.contains("app") })
        #expect(AskKeywordKind(pluginID: AskAppSearchPlugin.id) == .apps)
        var draft = AskKeywordDraft(adding: .apps)
        draft.keyword = "applications"
        #expect(draft.result().pluginID == AskAppSearchPlugin.id)
    }

    @Test func searchesOnlyApplications() async throws {
        let safari = AskTestAppIndex.app("Safari")
        let pane = AskAppEntry(name: "Safari Settings", url: URL(fileURLWithPath: "/Settings/Safari.appex"),
                               bundleID: "test.safari.settings", names: [], kind: .settingsPane)
        let index = AskTestAppIndex([pane, safari])
        let plugin = AskAppSearchPlugin(index: { index })
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        let plan = await plugin.plan(request(""))
        #expect(plan.mode == .live)
        let all = try await plugin.run(request(""), plan: plan, progress: { _ in })
        #expect(all.items.map(\.title) == ["Safari"])
        #expect(all.applicationGrid)
        let found = try await plugin.run(request("saf"), plan: plan, progress: { _ in })
        #expect(found.items.map(\.title) == ["Safari"])
        #expect(found.applicationGrid)
        #expect(found.action(for: .enter)?.kind == .openApplication(safari))
        let selected = try await plugin.run(request("saf", origin: .selection), plan: plan, progress: { _ in })
        #expect(selected.items.map(\.title) == ["Safari"])
        #expect(index.refreshes == 3)
    }

    @Test func emptyAndDisabledResultsCannotOpenAnything() async throws {
        let index = AskTestAppIndex([])
        let plugin = AskAppSearchPlugin(index: { index })
        let plan = await plugin.plan(request("missing"))
        let empty = try await plugin.run(request("missing"), plan: plan, progress: { _ in })
        #expect(empty.items.count == 1 && empty.items[0].valid == false)
        #expect(!empty.applicationGrid)
        #expect(empty.action(for: .enter) == nil)
        let disabled = AskAppSearchPlugin(index: { nil })
        let off = try await disabled.run(request("Safari"), plan: plan, progress: { _ in })
        #expect(off.items.count == 1 && off.items[0].valid == false)
        #expect(!off.applicationGrid)
        #expect(off.items[0].title == L("ask.plugin.apps.off"))
    }

    @Test func returnOpensTheSelectedAppAndRecordsItsLaunch() async throws {
        let safari = AskTestAppIndex.app("Safari")
        let index = AskTestAppIndex([safari])
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "app", apps: index)
        defer { launcher.close() }
        try await launcher.press(36)
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.plugins.output?.selected?.title == "Safari" }
        let action = try #require(launcher.fixture.model.plugins.output?.action(for: .enter))
        try await launcher.press(36)
        #expect(launcher.opened == [safari.url])
        #expect(index.launched == [safari.id])
        #expect(launcher.dismissed == 1)
        #expect(launcher.fixture.model.performPluginAction(action) == .stay)
    }
    @Test func gridMeasuresAndRendersApplicationItems() async throws {
        let apps = (0..<14).map { AskTestAppIndex.app("App \($0)", id: "grid.app.\($0)") }
        let index = AskTestAppIndex(apps)
        let plugin = AskAppSearchPlugin(index: { index })
        let plan = await plugin.plan(request(""))
        let output = try await plugin.run(request(""), plan: plan, progress: { _ in })
        #expect(output.items.compactMap(AskAppSearchGridView.application).count == 14)
        #expect(AskAppSearchGridView.height(count: 14) == AskApplicationGrid.height(count: 14))
        #expect(AskPluginResultsView.cardHeight(output: output, failure: nil, comparing: false) == 334)
        #expect(AskAppSearchGridView.height(count: 14, viewportHeight: 600) == 565)
        #expect(AskAppSearchGridView.height(count: 200) == 430)
        let renderer = ImageRenderer(content: AskAppSearchGridView(output: output, pending: false,
            onSelect: { _ in true }, onMain: {}).frame(width: 740))
        #expect(renderer.nsImage != nil)
        let empty = try await AskAppSearchPlugin(index: { nil }).run(request(""), plan: plan, progress: { _ in })
        #expect(AskAppSearchGridView.application(empty.items[0]) == nil)
    }

    @Test func keywordGridNavigatesInTwoDimensionsAndOpensSelection() async throws {
        let apps = (0..<14).map { AskTestAppIndex.app(String(format: "App %02d", $0), id: "grid.app.\($0)") }
        let index = AskTestAppIndex(apps)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "app", apps: index)
        defer { launcher.close() }
        try await launcher.press(36)
        let session = launcher.fixture.model.plugins
        try await AskQuickSearchSessionTests.wait { session.output?.applicationGrid == true }
        try await launcher.press(125)
        #expect(session.output?.selectedItem == 6)
        try await launcher.press(124)
        #expect(session.output?.selectedItem == 7)
        try await launcher.press(123)
        #expect(session.output?.selectedItem == 6)
        try await launcher.press(126)
        #expect(session.output?.selectedItem == 0)
        let selected = try #require(session.output?.action(for: .enter))
        guard case let .openApplication(app) = selected.kind else {
            Issue.record("Grid selection must retain the application action")
            return
        }
        try await launcher.press(36)
        #expect(launcher.opened == [app.url])
        #expect(launcher.dismissed == 1)
    }

}
