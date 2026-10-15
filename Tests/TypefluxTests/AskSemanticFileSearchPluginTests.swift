import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private actor SemanticKeywordSearch: SemanticFileSearching {
    struct Request: Equatable {
        let text: String
        let type: AskFileType
        let limit: Int
    }

    private(set) var requests: [Request] = []
    let hits: [AskFileHit]
    let delay: Duration
    nonisolated let enabled: Bool
    @MainActor var isEnabled: Bool {
        enabled
    }

    init(hits: [AskFileHit] = [], enabled: Bool = true, delay: Duration = .zero) {
        self.hits = hits
        self.enabled = enabled
        self.delay = delay
    }

    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] {
        requests.append(.init(text: text, type: type, limit: limit))
        try? await Task.sleep(for: delay)
        return Array(hits.prefix(limit))
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskSemanticFileSearchPluginTests {
    private let keyword = AskSemanticFileSearchPlugin.keywords[0]
    private let hit = AskFileHit(path: "/work/guide.pdf", name: "guide.pdf", kind: .file,
                                 modified: Date(timeIntervalSince1970: 1), score: 0.7,
                                 evidence: .init(text: "Submit the expense form with receipts.", page: 3))

    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: keyword, options: [:], interfaceLanguage: .english)
    }

    private func plugin(_ service: SemanticKeywordSearch?) -> AskSemanticFileSearchPlugin {
        AskSemanticFileSearchPlugin(semantic: { service }, settings: { .init() })
    }

    @Test func `defaults migrate without claiming existing words or restoring deleted entries`() {
        let id = AskSemanticFileSearchPlugin.id
        #expect(AskPluginRegistry.pluginIDs.contains(id))
        #expect(AskPluginRegistry.defaultKeywords.contains(keyword))
        for word in keyword.allKeywords {
            #expect(AskKeywordMatcher.match(word.uppercased(), keywords: [keyword]) == .hint(keyword))
            #expect(AskKeywordMatcher.match(word + "：报销流程", keywords: [keyword]) == .active(keyword, argument: "报销流程"))
        }
        let known = AskPluginRegistry.coveredGroups.filter { $0 != id }
        let saved = AskPluginRegistry.defaultKeywords.filter { $0.pluginID != id }
        let migrated = AskPluginRegistry.keywords(saved: saved, known: known)
        #expect(migrated.filter { $0.pluginID == id } == [keyword])
        #expect(AskPluginRegistry.keywords(saved: migrated, known: AskPluginRegistry.coveredGroups) == migrated)
        #expect(!AskPluginRegistry.keywords(saved: saved, known: AskPluginRegistry.coveredGroups)
            .contains { $0.pluginID == id })
        let reserved = Set(keyword.allKeywords.map { $0.lowercased() })
        #expect(!AskPluginRegistry.keywords(saved: saved, known: known, reserved: reserved)
            .contains { $0.pluginID == id })
        let owner = AskKeyword(keyword: "SS", pluginID: AskPromptPlugin.id)
        let conflict = AskPluginRegistry.keywords(saved: saved + [owner], known: known)
        #expect(conflict.contains(owner))
        #expect(conflict.first { $0.pluginID == id }?.allKeywords == ["semanticsearch", "语义检索"])
        var disabled = keyword
        disabled.enabled = false
        #expect(AskPluginRegistry.keywords(saved: [disabled], known: AskPluginRegistry.coveredGroups) == [disabled])
    }

    @Test func `settings and directory expose an editable semantic entry`() throws {
        #expect(AskKeywordKind(pluginID: keyword.pluginID) == .semanticFiles)
        #expect(AskKeywordKind.semanticFiles.pluginID == keyword.pluginID)
        var draft = AskKeywordDraft(adding: .semanticFiles)
        draft.keyword = "meaning"
        draft.aliases = ["findcontent"]
        #expect(draft.canSave(among: [], workflows: []))
        #expect(draft.titlePlaceholder.isEmpty)
        #expect(draft.displayName == L("semantic.title"))
        let edited = draft.result()
        #expect(AskKeywordDraft(editing: edited).result() == edited)
        let rows = AskKeywordListPresentation.rows(keywords: [keyword], interface: .english, secondLanguage: "en")
        #expect(rows.first?.name == L("semantic.title"))
        #expect(rows.first?.summary == AskKeywordKind.semanticFiles.hint)
        #expect(AskKeywordSection.search.kinds.contains(.semanticFiles))
        #expect(AskKeywordKind.semanticFiles.tint == AskKeywordKind.files.tint)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        #expect(fixture.model.makeLauncherPlugins().contains { $0.id == keyword.pluginID })
        let entry = try #require(fixture.model.launcherKeywordDirectory(language: .english)
            .first { $0.keyword == keyword })
        #expect(entry.title == L("semantic.title") && entry.canEnter)
        #expect(AskFileSearchPlugin.showsFileResults(for: keyword.pluginID))
        #expect(AskFileSearchPlugin.showsFileResults(for: AskFileSearchPlugin.id))
        #expect(!AskFileSearchPlugin.showsFileResults(for: nil))
        #expect(!AskFileSearchPlugin.showsFileResults(for: AskWebSearchPlugin.id))
    }

    @Test func `searches only content and preserves filters limit and file actions`() async throws {
        let service = SemanticKeywordSearch(hits: [hit])
        var settings = AskLauncherSearchSettings()
        settings.limit = 7
        let configuration = settings
        let plugin = AskSemanticFileSearchPlugin(semantic: { service }, settings: { configuration })
        let request = request("How do I claim expenses? ext:pdf in:team")
        let plan = await plugin.plan(request)
        #expect(plan.mode == .live && plan.debounce == .milliseconds(16))
        #expect(plugin.id == keyword.pluginID && plugin.defaultKeywords == [keyword])
        #expect(plugin.placeholder(selectionLines: nil) == L("semantic.keyword.placeholder"))
        #expect(plugin.chipDetail(for: keyword, language: .english) == nil)
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
        var partials: [AskPluginOutput] = []
        let output = try await plugin.run(request, plan: plan) { partials.append($0) }
        #expect(await service.requests == [.init(text: request.text, type: .all, limit: 7)])
        #expect(partials.count == 1 && partials[0].items[0].loading && partials[0].selected == nil)
        #expect(output.items == [AskFileSearchPlugin.item(hit)])
        #expect(output.selected?.fileHit == hit && output.source == L("semantic.title"))
        #expect(output.selected?.excerpt == hit.evidence?.text)
        #expect(output.action(for: .enter)?.kind == .open(hit.url))
        #expect(output.action(for: .commandR)?.kind == .reveal(hit.url))
        #expect(output.action(for: .shiftCommandC)?.kind == .copy(hit.path))
    }

    @Test func `unavailable services offer settings without searching`() async throws {
        let disabled = SemanticKeywordSearch(enabled: false)
        for service in [nil, disabled] {
            let plugin = plugin(service)
            let request = request("expense form")
            let output = try await plugin.run(request, plan: plugin.plan(request))
            #expect(output.items.first?.title == L("semantic.keyword.unavailable"))
            #expect(output.action(for: .enter)?.kind == .openSettings)
        }
        #expect(await disabled.requests.isEmpty)
    }

    @Test(arguments: ["", "   ", "ext:pdf in:team", ".pdf", "a", "line\nnext", String(repeating: "a", count: 513)])
    func `invalid or empty queries do not search or list recent files`(_ text: String) async throws {
        let service = SemanticKeywordSearch(hits: [hit]), plugin = plugin(service)
        let request = request(text)
        let output = try await plugin.run(request, plan: plugin.plan(request))
        #expect(output.items.first?.title == L("semantic.keyword.query"))
        #expect(output.selected == nil && output.items.allSatisfy { $0.fileHit == nil })
        #expect(await service.requests.isEmpty)
    }

    @Test func `empty results stay empty and selected text waits for return`() async throws {
        let service = SemanticKeywordSearch(), plugin = plugin(service)
        let request = request("expense\r\nform", origin: .selection)
        let plan = await plugin.plan(request)
        #expect(plan.mode == .onSubmit)
        let output = try await plugin.run(request, plan: plan)
        #expect(await service.requests.first?.text == "expense form")
        #expect(output.items.first?.title == L("semantic.keyword.none") && output.selected == nil)
        #expect(output.items.allSatisfy { $0.fileHit == nil })
    }

    @Test func `cancellation discards late results`() async throws {
        let service = SemanticKeywordSearch(hits: [hit], delay: .seconds(5)), plugin = plugin(service)
        let request = request("expense form")
        let task = Task { try await plugin.run(request, plan: plugin.plan(request)) }
        defer { task.cancel() }
        for _ in 0 ..< 200 {
            if await service.requests.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.requests.count == 1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled search returned a result")
        } catch is CancellationError {} catch { throw error }
    }

    @Test func `real launcher runs aliases moves selection and opens content result`() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        var second = hit
        second.path = "/work/other.md"; second.name = "other.md"
        let service = SemanticKeywordSearch(hits: [hit, second])
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: "semanticsearch expense form",
            prepare: { model in
                model.semanticSearch = service
            }
        )
        defer { launcher.close() }
        launcher.fixture.model.openURL = { [weak launcher] url in launcher?.opened.append(url) }
        let session = launcher.fixture.model.plugins
        try await SemanticFileServiceTests.wait { session.output?.items.count == 2 }
        #expect(session.keyword == keyword)
        #expect(session.currentOutput?.selected?.fileHit == hit)
        try await launcher.press(AskQuickResultsInteractionTests.down)
        #expect(session.currentOutput?.selected?.fileHit == second)
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCREENSHOTS"] {
            let row = try #require(AskKeywordListPresentation.rows(keywords: [keyword], interface: .simplifiedChinese,
                                                                   secondLanguage: "en").first)
            try await SemanticFileSearchVisualTests.render(
                AskKeywordRowView(row: row, toggle: {}, open: {}).padding(24),
                width: 640,
                name: "semantic-keyword-settings"
            )
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                launcher.window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(150))
                let host = try #require(launcher.window.contentView)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("semantic-keyword-\(name).png"))
            }
        }
        try await launcher.press(AskQuickResultsInteractionTests.returnKey)
        #expect(launcher.opened == [second.url] && launcher.dismissed == 1)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }
}
