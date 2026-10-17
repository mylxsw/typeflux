import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("System info keyword", .serialized, .exclusiveUIState)
@MainActor
struct AskSystemInfoPluginTests {
    typealias F = SystemInfoFixtures

    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskSystemInfoPlugin.keywords[0], options: [:],
                         interfaceLanguage: .english)
    }

    @Test func `keywords and registration`() {
        withSystemMonitorLanguage {
            #expect(AskSystemInfoPlugin.keywords.map(\.allKeywords) == [["sys", "about", "本机", "配置"]])
            #expect(AskPluginRegistry.pluginIDs.contains(AskSystemInfoPlugin.id))
            let defaults = AskPluginRegistry.defaultKeywords.filter { $0.pluginID == AskSystemInfoPlugin.id }
            #expect(defaults.map(\.allKeywords) == [["sys", "about", "本机", "配置", "systeminfo"]])
            // No other default keyword answers to these words.
            let words = Set(["sys", "about", "本机", "配置", "systeminfo"])
            let others = AskPluginRegistry.defaultKeywords.filter { $0.pluginID != AskSystemInfoPlugin.id }
            #expect(others.flatMap(\.allKeywords).allSatisfy { !words.contains($0.lowercased()) })
            let plugin = AskSystemInfoPlugin()
            #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
            #expect(plugin.title == "System Info" && plugin.symbol == "info.circle")
            #expect(plugin.placeholder(selectionLines: 2) == "Find a setting: ip, serial, resolution, battery…")
            #expect(plugin.chipDetail(for: AskSystemInfoPlugin.keywords[0], language: .english) == nil)
            #expect(plugin.defaultKeywords == AskSystemInfoPlugin.keywords && plugin.optionName == nil)
        }
    }

    @Test func `saved keyword lists gain sys`() {
        let saved = [AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)]
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskSystemInfoPlugin.id }
        let keywords = AskPluginRegistry.keywords(saved: saved, known: known)
        for word in ["sys", "本机", "about"] {
            if case let .hint(found)? = AskKeywordMatcher.match(word, keywords: keywords) {
                #expect(found.pluginID == AskSystemInfoPlugin.id)
            } else {
                Issue.record("`\(word)` should offer system info")
            }
        }
        if case let .active(found, argument)? = AskKeywordMatcher.match("sys ip", keywords: keywords) {
            #expect(found.pluginID == AskSystemInfoPlugin.id && argument == "ip")
        } else {
            Issue.record("`sys ip` should search system info")
        }
    }

    @Test func `runs live and carries the filter`() async throws {
        let plugin = AskSystemInfoPlugin()
        let plan = await plugin.plan(request("ip"))
        #expect(plan.mode == .live && plan.debounce == .zero)
        let output = try await plugin.run(request("ip"), plan: plan, progress: { _ in })
        #expect(output.body == "ip" && output.items.isEmpty)
        let selection = try await plugin.run(
            request("selected words", origin: .selection),
            plan: plan,
            progress: { _ in }
        )
        #expect(selection.body.isEmpty)
        #expect(plugin.nextOptions(after: plan, request: request(""), step: 1) == nil)
    }

    @Test func `effects copy and show sections`() throws {
        try withSystemMonitorLanguage {
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            let model = fixture.model
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("system.info.\(UUID().uuidString)"))
            let previous = AskQuickResults.pasteboard
            AskQuickResults.pasteboard = pasteboard
            defer { AskQuickResults.pasteboard = previous; pasteboard.releaseGlobally() }

            #expect(!model.showsSystemInfo)
            #expect(model.performSystemInfoEffect(.handled) == .stay)
            #expect(model.performSystemInfoEffect(.unhandled) == .stay)
            #expect(model.performSystemInfoEffect(.copy("192.168.1.23")) == .stay)
            #expect(pasteboard.string(forType: .string) == "192.168.1.23")
            #expect(model.commandFeedback == "Copied")
            #expect(model.performSystemInfoEffect(.copyReport("## Mac\n")) == .stay)
            #expect(pasteboard.string(forType: .string) == "## Mac\n")
            #expect(model.commandFeedback == "Report copied (sensitive values left out)")
            model.launcherDraft.text = "ip"
            #expect(model.performSystemInfoEffect(.showSection(.network)) == .stay)
            #expect(model.launcherDraft.text.isEmpty && model.systemInfo.section == .network)
            var opened: [URL] = []
            model.openApplication = { opened.append($0) }
            model.launcherDraft.text = "sys"
            #expect(model.enterLauncherKeywordFromText(pluginID: AskSystemInfoPlugin.id))
            #expect(model.performSystemInfoEffect(.openApp) == .close)
            #expect(opened.map(\.lastPathComponent) == ["System Information.app"])
            #expect(!model.showsSystemInfo, "the next launch starts out of the keyword")
        }
    }

    @Test func `entering the keyword shows the view`() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.launcherDraft.text = "sys"
        #expect(model.enterLauncherKeywordFromText(pluginID: AskSystemInfoPlugin.id))
        #expect(model.showsSystemInfo && model.launcherDraft.text.isEmpty)
        model.plugins.deactivate()
        model.launcherDraft.text = "本机 序列号"
        #expect(model.enterLauncherKeywordFromText(pluginID: AskSystemInfoPlugin.id))
        #expect(model.showsSystemInfo && model.launcherDraft.text == "序列号")
        model.plugins.deactivate()
        model.launcherDraft.text = "top"
        #expect(!model.enterLauncherKeywordFromText(pluginID: AskSystemInfoPlugin.id))
    }

    @Test func `display takes the results place`() {
        let display = AskPluginDisplay(title: "System Info", symbol: AskSystemInfoPlugin.symbol, phase: .waiting,
                                       systemInfo: true)
        #expect(AskPluginResultsView.height(for: display) == SystemInfoLauncherView.height)
        #expect(AskPluginResultsView.hint(for: display).isEmpty)
    }

    // MARK: Views

    /// Lays a view out in a window so its body runs, as on screen.
    private func render(_ view: some View, width: CGFloat = AskMetrics.launcherWidth) {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        window.close()
    }

    @Test func `views render every state`() async {
        await withSystemMonitorLanguageAsync {
            let store = SystemInfoStore(reader: FakeSystemInfoReader(), now: { F.now })
            let model = SystemInfoLauncherModel()
            var effects: [SystemInfoEffect] = []
            let view = { (filter: String) in
                SystemInfoLauncherView(store: store, model: model, filter: filter) { effects.append($0) }
            }
            render(view(""))
            await store.settle()
            #expect(store.snapshot != nil)
            render(view(""))
            for section in SystemInfoSection.allCases {
                model.show(section)
                render(view(""))
            }
            model.show(.system)
            model.select("system.serial")
            model.toggleReveal("system.serial")
            render(view(""))
            render(view("ip"))
            render(view("nothing-like-this"))
            render(SystemInfoHintSummary(store: store))
            render(SystemInfoBar(fraction: 1.4, color: .blue))
            #expect(effects.isEmpty)
            #expect(SystemInfoTheme.color(.good) != SystemInfoTheme.color(.warning))
            #expect(SystemInfoSection.allCases.map(\.symbol).allSatisfy { !$0.isEmpty })
        }
    }
}
