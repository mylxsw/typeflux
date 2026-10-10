import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskLauncherFeatureSearchTests {
    private func entry(_ keyword: String, title: String, enabled: Bool = true) -> AskLauncherSearchEntry {
        .init(keyword: .init(keyword: keyword, pluginID: "workflow." + keyword, enabled: enabled),
              title: title, detail: "Description", symbol: "terminal")
    }

    @Test func `matches keywords and names with stable ranking`() {
        let entries = [entry("suffix", title: "Export JSON"), entry("js", title: "JSON Tools"),
                       entry("json", title: "Format"), entry("off", title: "JSON", enabled: false)]
        #expect(AskLauncherSearchEntry.search(entries, text: " JsOn ").map(\.keyword.keyword) == [
            "json",
            "js",
            "suffix"
        ])
        #expect(AskLauncherSearchEntry.search(entries, text: "DESCRIPTION").isEmpty)
        #expect(AskLauncherSearchEntry.search(entries, text: "ext:json").isEmpty)
        #expect(AskLauncherSearchEntry.search(entries, text: " ").isEmpty)
        #expect(AskLauncherSearchEntry.search(entries, text: "json", limit: 1).count == 1)
    }

    @Test func `features precede applications even in files first mode`() throws {
        var settings = AskLauncherSearchSettings()
        settings.mode = .filesFirst
        let result = try #require(AskQuickResults.assemble("json", matches: [
            .init(entry: AskTestAppIndex.app("JSON Editor"), score: 1)
        ], hits: [], status: nil, settings: settings, entries: [entry("js", title: "JSON Tools")]))
        #expect(result.rows == [.feature(0), .app(0), .askAI])
        #expect(result.best == .feature(0) && result.highlightedRow == .feature(0))
        #expect(result.identity(of: .feature(0)) == "feature:workflow.js:js")
        #expect(result.value(of: .feature(0)) == nil)
        #expect(AskQuickResultsView.section(of: .feature(0)) == .features)
        #expect(AskQuickResultsView.rowHeight(.feature(0)) == AskQuickResultsView.appHeight)
        #expect(!AskQuickResultsView.hint(for: result).isEmpty)
    }

    @Test func `preserves user choice across feature reordering`() throws {
        let entries = [entry("a", title: "JSON Export"), entry("b", title: "JSON")]
        var previous = try #require(AskQuickResults.search("json", sources: .init(entries: entries)))
        previous.highlight(1)
        var next = try #require(AskQuickResults.search("json", sources: .init(entries: entries.reversed())))
        next.keepChoice(from: previous)
        #expect(next.identity(of: next.highlightedRow) == previous.identity(of: previous.highlightedRow))
        #expect(next.chosen)
    }

    @Test func `supports feature search when app and file search are off`() {
        let session = AskQuickSearchSession()
        session.update(text: "json", chinese: false, calculator: false,
                       sources: .init(entries: [entry("js", title: "JSON Tools")]))
        #expect(session.presentation?.features.count == 1)
        #expect(!session.isSearching && session.pendingResults == nil)
        session.update(text: "other", chinese: false, calculator: false, sources: .init())
        #expect(session.presentation == nil)
    }

    @Test func `publishes features immediately and keeps them in later batches`() async throws {
        let index = AskControlledSearchIndex()
        index.appSearch = { _ in
            Thread.sleep(forTimeInterval: 0.03)
            return [.init(entry: AskTestAppIndex.app("JSON Editor"), score: 1)]
        }
        let session = AskQuickSearchSession()
        session.update(text: "json", chinese: false, calculator: false,
                       sources: .init(apps: index, entries: [entry("js", title: "JSON Tools")]))
        #expect(session.results?.best == .feature(0) && session.pendingResults == nil)
        try await AskQuickSearchSessionTests.wait { !session.isSearching }
        #expect(session.results?.rows == [.feature(0), .app(0), .askAI])
    }

    @Test func `discovering and entering A keyword clears query without running it`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let entries = fixture.model.launcherSearchEntries(language: .english)
        let polish = try #require(entries.first { $0.keyword.keyword == "rw" })
        fixture.model.launcherDraft.text = "Polish"
        fixture.model.enterLauncherSearchEntry(polish)
        #expect(fixture.model.plugins.keyword == polish.keyword)
        #expect(fixture.model.launcherDraft.text.isEmpty)
        #expect(!fixture.model.plugins.isRunning)
        #expect(await fixture.api.sends.isEmpty)
        #expect(entries.count(where: { $0.command != nil }) == AskSystemCommand.allCases.count)
    }

    @Test func `return enters partial keyword and tab enters name match`() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for (text, key) in [("transl", UInt16(36)), ("Polish", UInt16(48))] {
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: text)
            defer { launcher.close() }
            #expect(launcher.fixture.model.quickSearch.results?.best == .feature(0))
            let expected = try #require(launcher.fixture.model.quickSearch.results?.features.first?.keyword)
            try await launcher.press(key)
            #expect(launcher.fixture.model.plugins.keyword == expected)
            #expect(launcher.fixture.model.launcherDraft.text.isEmpty && launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `selecting ask AI after exact keyword does not force local entry`() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "prefix")
        defer { launcher.close() }
        let results = try #require(launcher.fixture.model.quickSearch.results)
        #expect(results.features.count == 1)
        try await launcher.press(125)
        try await launcher.press(36)
        #expect(try await launcher.sentCount() == 1)
        #expect(!launcher.fixture.model.plugins.isActive)
    }

    @Test func `tab on A system command enters its plan without executing`() async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "Display Sleep")
        defer { launcher.close() }
        #expect(launcher.fixture.model.quickSearch.results?.features.first?.command == .displaySleep)
        try await launcher.press(48)
        #expect(launcher.fixture.model.plugins.keyword?.pluginID == AskSystemCommand.displaySleep.id)
        #expect(launcher.dismissed == 0 && !launcher.fixture.model.plugins.isRunning)
        #expect(launcher.fixture.model.launcherDraft.text.isEmpty)
    }

    @Test func `searches installed workflow names and keywords while excluding disabled and conflicting entries`(
    ) throws {
        let workflows = try AskWorkflowFixture()
        try workflows.write(
            "json-tool",
            manifest: AskWorkflowFixture.inline("json-tool", keyword: "jq", script: "echo hi",
                                                extra: ["name": "Format JSON"])
        )
        try workflows.write(
            "disabled",
            manifest: AskWorkflowFixture.inline("disabled", keyword: "disabled", script: "echo hi",
                                                extra: ["name": "Disabled JSON"])
        )
        try workflows.write(
            "conflict",
            manifest: AskWorkflowFixture.inline("conflict", keyword: "fy", script: "echo hi",
                                                extra: ["name": "Conflicting JSON"])
        )
        workflows.store.setEnabled("disabled", false)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.workflows = workflows.store
        fixture.model.plugins.replacePlugins(fixture.model.makeLauncherPlugins())
        let entries = fixture.model.launcherSearchEntries(language: .english)
        #expect(AskLauncherSearchEntry.search(entries, text: "json").map(\.keyword.keyword) == ["jq"])
        let workflow = try #require(AskLauncherSearchEntry.search(entries, text: "jq").first)
        fixture.model.launcherDraft.text = "json"
        fixture.model.enterLauncherSearchEntry(workflow)
        #expect(fixture.model.plugins.keyword?.pluginID == "workflow.json-tool")
        #expect(!fixture.model.plugins.isRunning && fixture.model.launcherDraft.text.isEmpty)
    }

    @Test func `renders feature search and system settings`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_FEATURE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let oldLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(oldLanguage) }
        let settings = fixture.model.modelLibrary.settings
        let workflows = AskWorkflowStore(settings: settings, root: root.appendingPathComponent("workflows"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let results = try #require(AskQuickResults.search("切换", sources: .init(
                entries: fixture.model.launcherSearchEntries(language: .simplifiedChinese)
            )))
            try await render(
                AskQuickResultsView(results: results, question: "切换", onRun: { _, _ in }, onHighlight: { _ in }),
                size: .init(width: 680, height: 370),
                appearance: appearance,
                file: root.appendingPathComponent("features-" + name + ".png")
            )
            try await render(
                AskLauncherPluginSettingsView(settings: settings, workflows: workflows, initialFilter: .system),
                size: .init(width: 740, height: 1080),
                appearance: appearance,
                file: root.appendingPathComponent("system-settings-" + name + ".png")
            )
        }
    }

    private func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        _ = NSApplication.shared
        let window = AskTestVoiceWindow(
            contentRect: .init(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view.padding(16).background(ModelVisualStyle.canvas))
        hosting.frame = .init(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
}
