import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private actor BrowserSearchTestRunner: ProcessCommandRunning {
    var calls: [String] = []
    var response: String
    init(response: String =
        #"{"tabs":[{"windowID":"1","tabID":"2","index":1,"title":"Project","url":"https://example.com"}]}"#) {
        self.response = response
    }

    func run(
        executablePath _: String,
        arguments: [String],
        environment _: [String: String]?,
        currentDirectoryURL _: URL?
    ) async throws -> ProcessCommandResult {
        calls.append(arguments.last ?? "")
        return .init(stdout: response, stderr: "", exitCode: 0)
    }

    func setResponse(_ text: String) {
        response = text
    }
}

private actor BrowserSearchTestService: AskBrowserSearching {
    var entries: [AskBrowserSearchEntry]
    var calls = 0
    var delay: Duration
    init(entries: [AskBrowserSearchEntry] = [], delay: Duration = .zero) {
        self.entries = entries; self.delay = delay
    }

    func snapshot(kind: AskBrowserSearchEntry.Kind, browsers: [AskSearchBrowser],
                  interactive _: Bool) async -> AskBrowserSearchSnapshot {
        calls += 1
        try? await Task.sleep(for: delay)
        return .init(entries: entries.filter { $0.kind == kind && browsers.contains($0.browser) })
    }

    func focus(_: AskBrowserTabTarget) async throws {}
}

@Suite(.exclusiveUIState)
@MainActor
struct AskBrowserSearchTests {
    private func entry(
        _ title: String = "Project",
        url: String = "https://example.com",
        kind: AskBrowserSearchEntry.Kind = .bookmark,
        browser: AskSearchBrowser = .chrome,
        id: String = "1"
    ) -> AskBrowserSearchEntry {
        .init(id: id, kind: kind, browser: browser, title: title, url: url, folder: "Work", profile: "Personal",
              target: kind == .tab ? .init(browser: browser, windowID: "7", tabID: "8", index: 2, url: url) : nil)
    }

    private func request(_ plugin: AskBrowserSearchPlugin, text: String = "") -> AskPluginRequest {
        .init(
            text: text,
            origin: .argument,
            keyword: plugin.defaultKeywords[0],
            options: [:],
            interfaceLanguage: .english
        )
    }

    @Test func `browser identifiers and paths cover all requested browsers`() {
        #expect(AskSearchBrowser.allCases.count == 5)
        #expect(Set(AskSearchBrowser.allCases.map(\.bundleID)).count == 5)
        #expect(AskSearchBrowser.dia.bundleID == "company.thebrowser.dia")
        #expect(AskSearchBrowser.arc.bookmarkRoot.hasSuffix("Arc"))
        #expect(AskSearchBrowser.edge.bookmarkRoot.hasSuffix("Microsoft Edge"))
    }

    @Test func `words match across title URL folder and profile and exact title leads`() {
        let rows = [entry("Other", id: "other"), entry("Café Project", id: "cafe"), entry("Project", id: "exact")]
        #expect(AskBrowserSearchEntry.search(rows, query: "project", limit: 100).map(\.id) == ["exact", "cafe"])
        #expect(AskBrowserSearchEntry.search(rows, query: "cafe personal example", limit: 100).map(\.id) == ["cafe"])
        #expect(AskBrowserSearchEntry.search(rows, query: "work", limit: 1).count == 1)
        #expect(AskBrowserSearchEntry.search(rows, query: "missing", limit: 100).isEmpty)
        #expect(AskBrowserSearchEntry.search(rows, query: "", limit: 0).isEmpty)
    }

    @Test func `bookmark actions use source selected or default browser and copy URL`() throws {
        let bookmark = entry()
        let link = try #require(URL(string: bookmark.url))
        var preferences = AskBrowserSearchSettings()
        #expect(bookmark.item(settings: preferences).actions.first?.kind == .openIn(
            link,
            application: AskSearchBrowser.chrome.bundleID
        ))
        preferences.bookmarkBrowser = "safari"
        #expect(bookmark.item(settings: preferences).actions.first?.kind == .openIn(
            link,
            application: AskSearchBrowser.safari.bundleID
        ))
        preferences.bookmarkBrowser = "default"
        let item = bookmark.item(settings: preferences)
        #expect(item.actions.first?.kind == .open(link))
        #expect(item.actions.last?.kind == .copy(bookmark.url) && item.actions.last?.shortcut == .commandC)
        let tab = entry(kind: .tab)
        #expect(try tab.item(settings: preferences).actions.first?.kind == .focusBrowserTab(#require(tab.target)))
        #expect(!entry(url: "javascript:alert(1)").item(settings: preferences).valid)
    }

    @Test func `chromium reads nested folders and preserves profiles without running bookmarklets`() throws {
        let data = Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[{"type":"folder","name":"Work","children":[{"id":"42","type":"url","name":"Site","url":"https://example.com"},{"id":"43","type":"url","name":"Unsafe","url":"javascript:alert(1)"}]}]}}}"#
            .utf8)
        for browser in [AskSearchBrowser.chrome, .dia, .edge] {
            let rows = try AskBrowserBookmarks.chromium(data, browser: browser, profile: "Profile 2")
            #expect(rows.count == 1 && rows[0].folder == "Bar / Work" && rows[0].profile == "Profile 2")
            #expect(rows[0].id == browser.id + ":Profile 2:42")
        }
    }

    @Test func `safari supports binary property lists and excludes reading list`() throws {
        let bookmark: [String: Any] = [
            "URLString": "https://example.com",
            "URIDictionary": ["title": "Example"],
            "WebBookmarkUUID": "id"
        ]
        let root: [String: Any] = ["Children": [["Title": "BookmarksBar", "Children": [bookmark]],
                                                ["Title": "com.apple.ReadingList", "Children": [bookmark]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let rows = try AskBrowserBookmarks.safari(data)
        #expect(rows.count == 1 && rows[0].title == "Example" && rows[0].folder == "BookmarksBar")
    }

    @Test func `arc includes favorites pinned folders and split tabs but excludes daily tabs and cycles`() throws {
        let data = Data(#"{"sidebar":{"containers":[{}, {"topAppsContainerIDs":["profile","fav"],"spaces":["space",{"title":"Work","newContainerIDs":[{"unpinned":{}},"daily",{"pinned":{}},"pinned"]}],"items":["fav",{"childrenIds":["f"]},"f",{"data":{"tab":{"savedURL":"https://fav.com","savedTitle":"Favorite"}}},"pinned",{"childrenIds":["folder"]},"folder",{"title":"Docs","childrenIds":["p","pinned","split"]},"p",{"data":{"tab":{"savedURL":"https://pin.com","savedTitle":"Pinned"}}},"split",{"data":{"splitView":{}},"childrenIds":["s"]},"s",{"data":{"tab":{"savedURL":"https://split.com","savedTitle":"Split"}}},"daily",{"childrenIds":["d"]},"d",{"data":{"tab":{"savedURL":"https://daily.com","savedTitle":"Daily"}}}]}]}}"#
            .utf8)
        let rows = try AskBrowserBookmarks.arc(data)
        #expect(rows.map(\.title) == ["Favorite", "Pinned", "Split"])
        #expect(rows[1].folder == "Work / Docs")
    }

    @Test func `reading profiles skips missing files and reports corrupt data with partial results`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(AskSearchBrowser.chrome.bookmarkRoot)
        for profile in ["Default", "Profile 1", "Empty"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(profile),
                withIntermediateDirectories: true
            )
        }
        let data = Data(#"{"roots":{"bar":{"type":"url","id":"1","name":"Site","url":"https://site.com"}}}"#.utf8)
        try data.write(to: root.appendingPathComponent("Default/Bookmarks"))
        try Data("bad".utf8).write(to: root.appendingPathComponent("Profile 1/Bookmarks"))
        let snapshot = AskBrowserBookmarks.read(.chrome, home: home)
        #expect(snapshot.entries.count == 1 && snapshot.issues == [.init(browser: .chrome, reason: .unreadable)])
        #expect(AskBrowserBookmarks.read(.edge, home: home).entries.isEmpty)
        #expect(AskBrowserBookmarks.read(.safari, home: home).issues.isEmpty)
    }

    @Test func `scripts use browser specific selectors and validate identity before focus`() throws {
        for browser in AskSearchBrowser.allCases {
            let target = AskBrowserTabTarget(
                browser: browser,
                windowID: "7",
                tabID: "8",
                index: 2,
                url: "https://example.com/\"\n"
            )
            let list = AskBrowserTabScripts.list(browser)
            let focus = AskBrowserTabScripts.focus(target)
            #expect(list.contains("if (!app.running())") && !list.contains("app.activate()"))
            #expect(focus.contains("tab.url() !==") && focus.contains("return 'missing'"))
            #expect(focus.contains(AskBrowserTabScripts.literal(target.url)))
            switch browser {
            case .safari: #expect(focus.contains("currentTab = tab"))
            case .chrome, .edge: #expect(focus.contains("activeTabIndex"))
            case .dia: #expect(focus.contains("app.focus(tab)") && list.contains("window.profiles()"))
            case .arc: #expect(focus.contains("app.select(tab)") && list.contains("window.spaces()"))
            }
        }
        let json = #"{"tabs":[{"windowID":"1","tabID":"2","index":1,"title":"Line\n\"Title\"","url":"https://a.com"},{"windowID":"1","tabID":"3","index":0,"url":""}]}"#
        let rows = try AskBrowserTabScripts.parse(json, browser: .dia).entries
        #expect(rows.count == 1 && rows[0].title == "Line\n\"Title\"")
        #expect(try AskBrowserTabScripts.parse(#"{"error":-1743}"#, browser: .safari).issues.first?
            .reason == .automation)
        #expect(throws: (any Error).self) { try AskBrowserTabScripts.parse("bad", browser: .chrome) }
    }

    @Test func `background does not prompt or start closed browsers and explicit search can request permission`() async {
        let runner = BrowserSearchTestRunner()
        let closed = AskBrowserSearchService(runner: runner, running: { _ in false }, authorized: { _ in true })
        #expect(await closed.snapshot(kind: .tab, browsers: AskSearchBrowser.allCases, interactive: true).entries
            .isEmpty)
        #expect(await runner.calls.isEmpty)
        let service = AskBrowserSearchService(runner: runner, running: { _ in true }, authorized: { _ in
            #expect(!Thread.isMainThread, "A system permission check must not block the launcher UI")
            return false
        })
        #expect(await service.snapshot(kind: .tab, browsers: [.chrome], interactive: false).entries.isEmpty)
        #expect(await runner.calls.isEmpty)
        async let first = service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        async let second = service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        let (a, b) = await (first, second)
        #expect(a.entries.count == 1 && b.entries == a.entries)
        #expect(await runner.calls.count == 1)
        _ = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        #expect(await runner.calls.count == 1)
    }

    @Test func `focus rejects missing tabs and clears cache after success`() async throws {
        let runner = BrowserSearchTestRunner()
        let service = AskBrowserSearchService(runner: runner, running: { _ in true })
        let snapshot = await service.snapshot(kind: .tab, browsers: [.chrome], interactive: true)
        let target = try #require(snapshot.entries.first?.target)
        await runner.setResponse("missing")
        await #expect(throws: AskPluginFailure.self) { try await service.focus(target) }
        await runner.setResponse("focused")
        try await service.focus(target)
        #expect(await runner.calls.count == 3)
    }

    @Test func `plugins list without selection and respect feature and browser toggles`() async throws {
        let service = BrowserSearchTestService(entries: [entry(kind: .tab), entry(browser: .safari)])
        for kind in [AskBrowserSearchEntry.Kind.tab, .bookmark] {
            let plugin = AskBrowserSearchPlugin(kind: kind, service: service, settings: { .init() })
            let input = request(plugin)
            let plan = await plugin.plan(input)
            #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn && plan
                .mode == .live)
            let result = try await plugin.run(input, plan: plan)
            #expect(result.items.count == 1 && result.items[0].valid && result.rerunAfter != nil)
            var noMatch = input; noMatch.text = "missing"
            #expect(try await plugin.run(noMatch, plan: plan).items.allSatisfy { !$0.valid })
            var selection = input; selection.origin = .selection; selection.text = "ignored"
            #expect(try await plugin.run(selection, plan: plan).items[0].valid)
        }
        let disabled = AskBrowserSearchPlugin(kind: .tab, service: service, settings: {
            var value = AskBrowserSearchSettings(); value.tabsEnabled = false; return value
        })
        let count = await service.calls
        #expect(try await disabled.run(request(disabled), plan: disabled.plan(request(disabled))).items
            .allSatisfy { !$0.valid })
        #expect(await service.calls == count)
    }

    @Test func `new keywords do not displace custom keywords or workflows and are editable`() {
        let old = [AskKeyword(keyword: "tab", pluginID: AskPromptPlugin.id)]
        let merged = AskPluginRegistry.keywords(saved: old, known: [AskPromptPlugin.id], reserved: ["bmk"])
        #expect(merged.contains(old[0]))
        #expect(!merged.contains { $0.pluginID == AskBrowserSearchPlugin.tabsID && $0.contains("tab") })
        #expect(!merged.contains { $0.pluginID == AskBrowserSearchPlugin.bookmarksID && $0.contains("bmk") })
        for keyword in AskBrowserSearchPlugin.keywords {
            let draft = AskKeywordDraft(editing: keyword)
            #expect(draft.result() == keyword && draft.fieldProblem == nil)
            #expect(!draft.displayName.isEmpty && AskKeywordKind(pluginID: keyword.pluginID) != nil)
        }
    }

    @Test func `preferences persist independently and announce changes`() throws {
        let suite = "browser-search-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.askBrowserSearchSettings.tabBrowsers == AskSearchBrowser.allCases)
        var preferences = store.askBrowserSearchSettings
        preferences.tabBrowsers = [.dia, .arc]; preferences.bookmarkBrowsers = [.safari]
        preferences.directTabs = false; preferences.bookmarkBrowser = "edge"
        store.askBrowserSearchSettings = preferences
        #expect(SettingsStore(defaults: defaults).askBrowserSearchSettings == preferences)
        #expect(store.askLauncherSearchSettings == AskLauncherSearchSettings())
    }

    @Test func `direct search publishes browser rows and discards previous queries`() async throws {
        let service = BrowserSearchTestService(entries: [entry(kind: .tab, id: "tab"), entry("Other", id: "bookmark")])
        let session = AskQuickSearchSession()
        let sources = AskQuickResults.Sources(browsers: service)
        session.update(text: "Project", chinese: false, calculator: false, sources: sources)
        try await Task.sleep(for: .milliseconds(350))
        #expect(session.results?.browserEntries.map(\.id) == ["tab"] && !session.isSearching)
        session.update(text: "Other", chinese: false, calculator: false, sources: sources)
        #expect(session.results?.browserEntries.isEmpty != false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(session.results?.browserEntries.map(\.id) == ["bookmark"])
        session.setVisible(false)
        #expect(session.results == nil)
    }

    @Test func `direct toggles and file filters prevent browser work`() async throws {
        let service = BrowserSearchTestService(entries: [entry()])
        let session = AskQuickSearchSession()
        var settings = AskBrowserSearchSettings(); settings.directTabs = false; settings.directBookmarks = false
        session.update(
            text: "Project",
            chinese: false,
            calculator: false,
            sources: .init(browsers: service, browserSettings: settings)
        )
        try await Task.sleep(for: .milliseconds(180))
        #expect(await service.calls == 0)
        session.update(text: "ext:pdf", chinese: false, calculator: false, sources: .init(browsers: service))
        try await Task.sleep(for: .milliseconds(180))
        #expect(await service.calls == 0)
    }

    @Test func `browser rows keep selection by identity and have stable layout`() throws {
        var first = try #require(AskQuickResults.addingBrowsers([entry(id: "a"), entry("Other", id: "b")], to: nil))
        first.highlight(1)
        var next = try #require(AskQuickResults.addingBrowsers([entry("Other", id: "b"), entry(id: "a")], to: nil))
        next.keepChoice(from: first)
        #expect(next.highlightedRow == .browser(0) && next.identity(of: .browser(0)) == "browser:b")
        #expect(AskQuickResultsView.section(of: .browser(0), in: next) == .bookmarks)
        #expect(AskQuickResultsView.rowHeight(.browser(0)) == AskQuickResultsView.appHeight)
        #expect(!AskQuickResultsView.hint(for: next).isEmpty)
    }

    @Test func `native script engine compiles all five browser adapters`() async throws {
        let runner = AskAutomationScriptRunner()
        let export = ProcessInfo.processInfo.environment["TYPEFLUX_BROWSER_SCRIPT_OUTPUT"]
            .map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        for browser in AskSearchBrowser.allCases {
            let target = AskBrowserTabTarget(
                browser: browser,
                windowID: "7",
                tabID: "8",
                index: 1,
                url: "https://example.com"
            )
            for source in [AskBrowserTabScripts.list(browser), AskBrowserTabScripts.focus(target)] {
                let script = "new Function(" + AskBrowserTabScripts.literal(source) + "); 'compiled';"
                let result = try await runner.run(
                    executablePath: "/usr/bin/osascript",
                    arguments: ["-l", "JavaScript", "-e", script],
                    environment: nil,
                    currentDirectoryURL: nil
                )
                #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "compiled")
            }
            if let export {
                try AskBrowserTabScripts.list(browser).write(
                    to: export.appendingPathComponent(browser.id + ".js"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    @Test func `browser settings and results render at compact and regular widths`() async throws {
        _ = NSApplication.shared
        let suite = "browser-search-visual-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let oldLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(oldLanguage) }
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_BROWSER_VISUAL_OUTPUT"]
            .map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func render(_ view: some View, width: CGFloat, height: CGFloat, name: String) async throws {
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top)
                .padding(16).background(ModelVisualStyle.canvas).environment(\.colorScheme, .dark))
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let directory {
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        for width in [CGFloat(620), 760] {
            let page = LauncherSearchSettingsView(
                settings: store,
                index: AskTestFileIndex(),
                fullDiskAccess: { true },
                tab: .browsers
            )
            try await render(page, width: width, height: 1540, name: "settings-\(Int(width))")
        }
        let results = try #require(AskQuickResults.addingBrowsers([
            entry("项目设计", kind: .tab, browser: .dia, id: "tab"),
            entry("开发文档", browser: .safari, id: "bookmark")
        ], to: nil))
        try await render(
            AskQuickResultsView(results: results, question: "项目", onRun: { _, _ in }, onHighlight: { _ in }),
            width: 680,
            height: 260,
            name: "direct-results"
        )
    }
}
