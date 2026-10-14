import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Workflow keyword selection", .serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowKeywordSelectionTests {
    private func setup(argument: String = "optional") throws -> (AskWorkflowFixture, AskTestFixture) {
        let workflows = try AskWorkflowFixture()
        try workflows.write("selection", manifest: AskWorkflowFixture.inline(
            "selection", keyword: "selection", script: "print -r -- \"ran:$1:$TYPEFLUX_SELECTION\"",
            extra: ["input": ["argument": argument, "selection": "always"]]
        ))
        workflows.store.reload()
        workflows.store.trust("selection")
        let fixture = try AskTestFixture()
        fixture.model.workflows = workflows.store
        fixture.model.plugins.replacePlugins(fixture.model.makeLauncherPlugins())
        return (workflows, fixture)
    }

    @Test func `gallery input requirements match useful defaults`() {
        let ready: Set = ["fx", "ts", "uuid", "ip", "code", "cron", "emoji"]
        let gallery = AskWorkflowGallery.bundled
        #expect(gallery.items.count == 18)
        for item in gallery.items {
            #expect((item.manifest.input.argument != .required) == ready.contains(item.id), "\(item.id)")
        }
        #expect(Set(gallery.items.filter { ready.contains($0.id) }.flatMap(\.keywords))
            == ["fx", "rate", "ts", "uuid", "pwd", "ip", "code", "cron", "emoji"])
    }

    @Test(arguments: ["none", "optional"])
    func `search selection runs without another return`(argument: String) async throws {
        let (workflows, fixture) = try setup(argument: argument)
        let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.keyword == "selection" })
        defer { fixture.model.resetSession(); _ = workflows }
        let entry = try #require(fixture.model.launcherSearchEntries(language: .english)
            .first { $0.keyword == keyword })
        fixture.model.launcherDraft.text = "Selection"
        fixture.model.enterLauncherSearchEntry(entry, run: true)
        try await fixture.wait { fixture.model.plugins.output != nil }
        #expect(fixture.model.plugins.output?.body == "ran::")
        #expect(fixture.model.launcherDraft.text.isEmpty)
    }

    @Test(arguments: ["search", "directory", "home"])
    func `required input waits until it is submitted`(entry: String) async throws {
        let (workflows, fixture) = try setup(argument: "required")
        let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.keyword == "selection" })
        defer { fixture.model.resetSession(); _ = workflows }
        fixture.model.launcherDraft.selection = "selected"
        switch entry {
        case "search":
            let entry = try #require(fixture.model.launcherSearchEntries(language: .english)
                .first { $0.keyword == keyword })
            fixture.model.enterLauncherSearchEntry(entry, run: true)
        case "directory":
            _ = fixture.model.performPluginAction(.init(kind: .enterKeyword(keyword.id), title: "", symbol: ""))
        default: fixture.model.enterLauncherKeyword(keyword, run: false)
        }
        #expect(fixture.model.plugins.keyword == keyword)
        #expect(fixture.model.plugins.request == nil && !fixture.model.plugins.isRunning)
        #expect(fixture.model.launcherDraft.sentSelection == "selected")
        fixture.model.plugins.update(text: "value", selection: "selected", language: .english)
        try await fixture.wait { fixture.model.plugins.isPlanCurrent }
        #expect(fixture.model.plugins.run())
        try await fixture.wait { fixture.model.plugins.output != nil }
        #expect(fixture.model.plugins.output?.body == "ran:value:selected")
    }

    @Test(arguments: ["directory", "home"])
    func `other keyword choices run optional workflows`(entry: String) async throws {
        let (workflows, fixture) = try setup()
        let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.keyword == "selection" })
        defer { fixture.model.resetSession(); _ = workflows }
        if entry == "directory" {
            _ = fixture.model.performPluginAction(.init(kind: .enterKeyword(keyword.id), title: "", symbol: ""))
        } else {
            fixture.model.enterLauncherKeyword(keyword, run: false)
        }
        try await fixture.wait { fixture.model.plugins.output != nil }
        #expect(fixture.model.plugins.output?.body == "ran::")
    }

    @Test func `tab entry and typing A separator still wait for return`() async throws {
        let (workflows, fixture) = try setup()
        let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.keyword == "selection" })
        defer { fixture.model.resetSession(); _ = workflows }
        let entry = try #require(fixture.model.launcherSearchEntries(language: .english)
            .first { $0.keyword == keyword })
        fixture.model.enterLauncherSearchEntry(entry)
        #expect(fixture.model.plugins.request == nil && !fixture.model.plugins.isRunning)
        fixture.model.plugins.deactivate()
        #expect(fixture.model.plugins.detect(in: "selection ") == "")
        fixture.model.plugins.update(text: "", selection: nil, language: .english)
        try await fixture.wait { fixture.model.plugins.isPlanCurrent }
        #expect(fixture.model.plugins.output == nil && !fixture.model.plugins.isRunning)
        #expect(fixture.model.plugins.run())
        try await fixture.wait { fixture.model.plugins.output != nil }
    }

    @Test func `builtin and stale search entries do not run A workflow`() throws {
        let (workflows, fixture) = try setup()
        let keyword = try #require(fixture.model.plugins.availableKeywords.first { $0.keyword == "selection" })
        defer { fixture.model.resetSession(); _ = workflows }
        #expect(!fixture.model.enterLauncherWorkflow(AskPrefixPlugin.keywords[0], run: true))
        let entry = try #require(fixture.model.launcherSearchEntries(language: .english)
            .first { $0.keyword == keyword })
        workflows.store.setEnabled("selection", false)
        fixture.model.plugins.replacePlugins(fixture.model.makeLauncherPlugins())
        fixture.model.enterLauncherSearchEntry(entry, run: true)
        #expect(!fixture.model.plugins.isActive && !fixture.model.plugins.isRunning)
    }

    @Test(arguments: ["uuid", "pwd"])
    func `one return copies and confirms the gallery result`(keyword: String) async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            try workflows.store.add(#require(AskWorkflowGallery.bundled.item("uuid")), builtIn: [])
            var notices: [String] = []
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "") { model in
                model.workflows = workflows.store
                model.passiveNotice = { notices.append($0) }
            }
            defer { launcher.close() }
            await launcher.fixture.model.refreshLauncherWorkflows()
            for character in keyword {
                launcher.editor.insertText(
                    String(character),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            try await launcher.fixture.wait {
                launcher.fixture.model.quickSearch.results?.features.first?.keyword.keyword == keyword
            }
            try await launcher.press(AskQuickResultsInteractionTests.returnKey)
            try await launcher.fixture.wait { launcher.dismissed == 1 }
            let copied = try #require(pasteboard.string(forType: .string))
            if keyword == "uuid" {
                #expect(UUID(uuidString: copied) != nil)
            } else {
                #expect(copied.count == 20 && !copied.contains(where: \.isWhitespace))
            }
            #expect(notices == [L("ask.workflow.gallery.uuid.copied")])
        }
    }

    @Test func `no input gallery scripts have successful nonempty defaults`() async throws {
        let workflows = try AskWorkflowFixture()
        let gallery = AskWorkflowGallery.bundled
        let tester = AskWorkflowTester(home: workflows.home.path)
        for item in gallery.items where item.manifest.input.argument != .required {
            let workflow = try workflows.store.add(item, builtIn: []).workflow
            if item.id == "fx" {
                let cache = AskWorkflow.cacheDirectory(for: workflow.id, home: workflows.home.path)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["USD": 1, "EUR": 0.9, "JPY": 150])
                    .write(to: cache.appendingPathComponent("rates-USD.json"))
            }
            for keyword in item.keywords {
                let result = await tester.run(workflow, input: .init(query: "", keyword: keyword))
                #expect(result.succeeded, "\(keyword): \(result.stderr)")
                #expect(!result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(keyword)")
            }
        }
    }

    @Test(arguments: [false, true])
    func `a keyword hint runs on return while tab only enters`(tab: Bool) async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { _ in
            let workflows = try AskWorkflowFixture()
            try workflows.write("selection", manifest: AskWorkflowFixture.inline(
                "selection", keyword: "selection", script: "print -r -- result"
            ))
            workflows.store.reload()
            workflows.store.trust("selection")
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "") { model in
                model.workflows = workflows.store
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            await model.refreshLauncherWorkflows()
            for character in "selection" {
                launcher.editor.insertText(
                    String(character),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            try await launcher.fixture.wait { model.plugins.hint?.keyword == "selection" }
            // Simulate the hint fallback while feature search has no presented batch.
            model.quickSearch.cancel()
            model.quickSearch.results = nil
            try await launcher.press(AskQuickResultsInteractionTests.down)
            if tab {
                try await launcher.press(AskQuickResultsInteractionTests.tab)
                #expect(model.plugins.isActive && model.plugins.output == nil && !model.plugins.isRunning)
            }
            try await launcher.press(AskQuickResultsInteractionTests.returnKey)
            try await launcher.fixture.wait { model.plugins.output?.body == "result" }
            #expect(launcher.dismissed == 0)
        }
    }

    @Test(arguments: [false, true])
    func `pending HUD survives closing once`(askAI: Bool) throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var events: [String] = []
        fixture.model.passiveNotice = { events.append($0) }
        let host = AskWorkflowLauncherActionHost(model: fixture.model) { events.append("dismiss") }
        host.hud("first")
        host.hud("last")
        #expect(events.isEmpty)
        if askAI {
            host.askAI("")
        } else {
            host.close()
        }
        #expect(events == ["dismiss", "last"])
        host.close()
        #expect(events == ["dismiss", "last"])
        host.hud("after")
        #expect(events == ["dismiss", "last", "after"])
    }
}
