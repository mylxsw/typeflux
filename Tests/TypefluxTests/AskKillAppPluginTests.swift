import Foundation
import Testing
@testable import Typeflux

@Suite("Force quit application keyword", .exclusiveUIState)
@MainActor
struct AskKillAppPluginTests {
    private func target(_ name: String, pid: Int32) -> AskKillAppTarget {
        AskKillAppTarget(app: AskAppEntry(name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                                         bundleID: "test.\(name)", names: []), processID: pid, launchDate: nil)
    }

    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskKillAppPlugin.keywords[0], options: [:],
                         interfaceLanguage: .english)
    }

    @Test func registrationMigrationAndSettings() {
        #expect(AskPluginRegistry.pluginIDs.contains(AskKillAppPlugin.id))
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskKillAppPlugin.id }
        let keywords = AskPluginRegistry.keywords(saved: [], known: known)
        #expect(keywords.contains { $0.keyword == "kill" && $0.pluginID == AskKillAppPlugin.id })
        #expect(AskKeywordMatcher.match("kill Safari", keywords: keywords) == .active(AskKillAppPlugin.keywords[0], argument: "Safari"))
        #expect(AskPluginRegistry.keywords(saved: [], known: AskPluginRegistry.coveredGroups).isEmpty)
        #expect(!AskPluginRegistry.keywords(saved: [], known: known, reserved: ["kill"]).contains { $0.contains("kill") })
        #expect(AskKeywordKind(pluginID: AskKillAppPlugin.id) == .kill)
        #expect(AskKeywordSection.system.kinds.contains(.kill))
        var draft = AskKeywordDraft(adding: .kill)
        draft.keyword = "stopapp"
        #expect(draft.result().pluginID == AskKillAppPlugin.id)
        #expect(draft.fieldProblem == nil)
    }

    @Test func listsOnlyRunningTargetsAndExcludesSelf() async throws {
        let safari = target("Safari", pid: 101)
        let chrome = target("Google Chrome", pid: 102)
        let own = target("Typeflux", pid: ProcessInfo.processInfo.processIdentifier)
        let plugin = AskKillAppPlugin(applications: { [safari, own, chrome] })
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        let plan = await plugin.plan(request(""))
        #expect(plan.mode == .live && plan.actions.isEmpty)
        let all = try await plugin.run(request(""), plan: plan, progress: { _ in })
        #expect(all.items.map(\.title) == ["Google Chrome", "Safari"])
        #expect(all.action(for: .enter)?.kind == .killApp(chrome))
        #expect(all.note == L("ask.plugin.kill.warning"))
        let filtered = try await plugin.run(request("saf"), plan: plan, progress: { _ in })
        #expect(filtered.items.map(\.title) == ["Safari"])
        #expect(filtered.action(for: .enter)?.kind == .killApp(safari))
        let initials = try await plugin.run(request("gc"), plan: plan, progress: { _ in })
        #expect(initials.items.map(\.title) == ["Google Chrome"])
        let selection = try await plugin.run(request("Safari", origin: .selection), plan: plan, progress: { _ in })
        #expect(selection.items == all.items)
    }

    @Test func noMatchesCannotQuitAnything() async throws {
        let plugin = AskKillAppPlugin(applications: { [] })
        let plan = await plugin.plan(request("missing"))
        let output = try await plugin.run(request("missing"), plan: plan, progress: { _ in })
        #expect(output.items.count == 1 && output.items[0].valid == false)
        #expect(output.action(for: .enter) == nil)
        #expect(plugin.nextOptions(after: plan, request: request(""), step: 1) == nil)
    }

    @Test func rejectsSelfAndVanishedTargets() {
        #expect(!AskKillAppPlugin.forceQuit(target("Typeflux", pid: ProcessInfo.processInfo.processIdentifier)))
        #expect(!AskKillAppPlugin.forceQuit(target("Gone", pid: Int32.max)))
    }

    @Test func launcherEntersKillAndRejectsUnselectedActions() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let action = AskPluginAction(kind: .killApp(target("Gone", pid: Int32.max)), title: "", symbol: "")
        #expect(model.performPluginAction(action) == .stay)
        model.launcherDraft.text = "kill Safari"
        #expect(model.enterLauncherKeywordFromText(pluginID: AskKillAppPlugin.id))
        #expect(model.plugins.keyword?.pluginID == AskKillAppPlugin.id)
        #expect(model.launcherDraft.text == "Safari")
        #expect(model.performPluginAction(action) == .stay)
        #expect(model.launcherSearchEntries(language: .english).contains { $0.keyword.pluginID == AskKillAppPlugin.id })
    }

    @Test func returnEntersListAndQuitsOnlyAfterChoosingAResult() async throws {
        let gone = target("Gone", pid: Int32.max)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "kill", prepare: { model in
            model.plugins.replacePlugins([AskKillAppPlugin(applications: { [gone] })])
        })
        defer { launcher.close() }
        try await launcher.press(36)
        #expect(launcher.fixture.model.plugins.keyword?.pluginID == AskKillAppPlugin.id)
        try await AskQuickSearchSessionTests.wait { launcher.fixture.model.plugins.output != nil }
        #expect(launcher.fixture.model.plugins.output?.selected?.title == "Gone")
        #expect(launcher.dismissed == 0)
        #expect(launcher.fixture.model.commandFeedback == nil)
        try await launcher.press(36)
        #expect(launcher.dismissed == 0)
        #expect(launcher.fixture.model.commandFeedback == L("ask.plugin.kill.failed", "Gone"))
        #expect(await launcher.fixture.api.sends.isEmpty)
    }
}
