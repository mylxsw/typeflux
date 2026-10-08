import Foundation
import Testing
@testable import Typeflux

/// A model that streams the pieces the test gives it, recording each prompt.
final class AskTestTextGenerator: AskTextGenerating, @unchecked Sendable {
    var pieces = ["Hello", ", ", "world"]
    var failure: Error?
    var delay: Duration = .zero
    private(set) var prompts: [(system: String, user: String)] = []

    func stream(systemPrompt: String, userPrompt: String) -> AsyncThrowingStream<String, Error> {
        prompts.append((systemPrompt, userPrompt))
        let pieces = pieces, failure = failure, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for piece in pieces {
                    if delay != .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(piece)
                }
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records progress from a run, on the main actor.
@MainActor
final class AskProgressRecorder {
    var bodies: [String] = []
    var progress: AskPluginProgress { { [self] output in bodies.append(output.body) } }
}

@Suite("Ask prompt plugin")
@MainActor
struct AskPromptPluginTests {
    private func request(_ text: String = "teh text", origin: AskPluginRequest.Origin = .argument,
                         options: [String: String] = [AskPromptPlugin.presetOption: "polish"]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskPromptPlugin.keywords[0], options: options,
                         interfaceLanguage: .english)
    }

    @Test func presetsAndOwnPromptsNameTheKeyword() {
        #expect(AskPromptPlugin.keywords.map(\.keyword) == ["rw", "sum", "ex"])
        #expect(AskPromptPlugin.name(of: ["preset": "summarize"]) == L("ask.plugin.prompt.preset.summarize"))
        #expect(AskPromptPlugin.name(of: ["preset": "polish", "title": " JD "]) == "JD")
        #expect(AskPromptPlugin.name(of: ["title": "  "]) == L("ask.plugin.prompt.title"))
        #expect(AskPromptPlugin.template(of: ["preset": "explain"])?.contains("{input}") == true)
        #expect(AskPromptPlugin.template(of: ["preset": "explain", "prompt": "Mine {input}"]) == "Mine {input}")
        #expect(AskPromptPlugin.template(of: ["prompt": " \n"]) == nil)
        #expect(AskPromptPlugin.template(of: ["preset": "unknown"]) == nil)
        #expect(AskPromptPlugin.userPrompt(template: "Fix: {input}!", input: "x") == "Fix: x!")
        #expect(AskPromptPlugin.userPrompt(template: "Make it formal \n", input: "x") == "Make it formal\n\nx")
        let plugin = AskPromptPlugin()
        #expect(plugin.chipDetail(for: AskPromptPlugin.keywords[1], language: .english) == L("ask.plugin.prompt.preset.summarize"))
        #expect(plugin.placeholder(selectionLines: nil) == L("ask.plugin.prompt.placeholder"))
        #expect(plugin.placeholder(selectionLines: 2) == L("ask.plugin.prompt.placeholder.selection", 2))
        #expect(plugin.defaultKeywords == AskPromptPlugin.keywords && plugin.optionName == nil)
        #expect(plugin.nextOptions(after: AskPluginPlan(mode: .onSubmit, title: ""), request: request(), step: 1) == nil)
    }

    @Test func itAlwaysWaitsForReturnAndNamesTheModel() async {
        // Named titles: other suites switch the interface language while this one awaits.
        let plugin = AskPromptPlugin(generator: AskTestTextGenerator(), modelName: { "gpt-test" })
        let own = ["title": "JD", "prompt": "As JD: {input}"]
        let typed = await plugin.plan(request(options: own))
        #expect(typed.mode == .onSubmit, "the AI never runs while typing")
        #expect(typed.title == "JD" && typed.values["prompt"] == "As JD: {input}")
        #expect(typed.meta == [AskPluginMeta(text: "gpt-test", emphasized: true)])
        let selected = await plugin.plan(request("a\nb", origin: .selection, options: own))
        #expect(selected.title.contains("JD") && selected.title.contains("2"))
        #expect(await AskPromptPlugin().plan(request()).meta.isEmpty, "no model, no model name")
    }

    @Test func resultsStreamInAndOfferTheSharedActions() async throws {
        let generator = AskTestTextGenerator()
        generator.pieces = ["Hello", ", ", "world\n"]
        let plugin = AskPromptPlugin(generator: generator, modelName: { "gpt-test" })
        let recorder = AskProgressRecorder()
        let selected = request("helo wrld", origin: .selection)
        let output = try await plugin.run(selected, plan: await plugin.plan(selected), progress: recorder.progress)
        #expect(recorder.bodies == ["Hello", "Hello, ", "Hello, world\n"])
        #expect(output.body == "Hello, world")
        #expect(output.sourceIsAI && output.source == L("ask.plugin.source.ai", "gpt-test") && output.meta.isEmpty)
        #expect(generator.prompts.first?.system == AskPromptPlugin.systemPrompt)
        #expect(generator.prompts.first?.user.hasSuffix("\n\nhelo wrld") == true)
        #expect(output.action(for: .enter)?.kind == .copy("Hello, world"))
        #expect(output.action(for: .optionEnter)?.title == L("ask.plugin.action.replace"))
        #expect(output.action(for: .commandR)?.kind == .rerun([:]))
        #expect(output.action(for: .commandD)?.kind == .compare)
        #expect(output.action(for: .commandC)?.kind == .copy("Hello, world"), "⌘C copies the result by default")
        #expect(output.actions.contains { if case .askAI = $0.kind { true } else { false } })
        let typed = try await plugin.run(request(), plan: await plugin.plan(request()))
        #expect(typed.action(for: .optionEnter)?.title == L("ask.plugin.action.insert"))
    }

    @Test func failuresSayWhatIsMissing() async throws {
        let none = AskPromptPlugin()
        await #expect(throws: AskPluginFailure(message: L("ask.plugin.prompt.noModel"), retry: false)) {
            try await none.run(request(), plan: await none.plan(request()))
        }
        let generator = AskTestTextGenerator()
        let plugin = AskPromptPlugin(generator: generator)
        let empty = request(options: ["title": "Mine"])
        await #expect(throws: AskPluginFailure(message: L("ask.plugin.prompt.noPrompt"), retry: false)) {
            try await plugin.run(empty, plan: await plugin.plan(empty))
        }
        generator.pieces = [" ", "\n"]
        await #expect(throws: AskPluginFailure(message: L("ask.plugin.prompt.empty"))) {
            try await plugin.run(request(), plan: await plugin.plan(request()))
        }
        struct Offline: Error {}
        generator.pieces = ["part"]
        generator.failure = Offline()
        await #expect(throws: Offline.self) { try await plugin.run(request(), plan: await plugin.plan(request())) }
    }

    @Test func theModelGeneratorStreamsTheService() async throws {
        let generator = AskLLMTextGenerator(service: AskTestCompletingLLM(result: "whole"))
        var pieces: [String] = []
        for try await piece in generator.stream(systemPrompt: "s", userPrompt: "u") { pieces.append(piece) }
        #expect(pieces == ["whole"])
        let failing = AskLLMTextGenerator(service: AskTestCompletingLLM(result: nil))
        await #expect(throws: AskTestCompletingLLM.Failed.self) {
            for try await _ in failing.stream(systemPrompt: "s", userPrompt: "u") {}
        }
        var none: [String] = []
        for try await piece in AskLLMTextGenerator(service: AskTestCompletingLLM(result: "")).stream(systemPrompt: "s", userPrompt: "u") {
            none.append(piece)
        }
        #expect(none.isEmpty, "an empty completion yields nothing")
    }
}

/// A service that only completes, to exercise the one-piece stream.
private final class AskTestCompletingLLM: LLMService, @unchecked Sendable {
    struct Failed: Error {}
    let result: String?
    init(result: String?) { self.result = result }
    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        guard let result else { throw Failed() }
        return result
    }

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String { "{}" }
}

@Suite("Ask web search plugin")
struct AskWebSearchPluginTests {
    private func request(_ text: String = "swift actors", origin: AskPluginRequest.Origin = .argument,
                         options: [String: String] = ["engine": "google"]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskWebSearchPlugin.keywords[0], options: options,
                         interfaceLanguage: .english)
    }

    @Test func enginesAndTemplatesMakeSafeLinks() throws {
        #expect(AskWebSearchPlugin.keywords.map(\.keyword) == ["g", "bd", "gh"])
        #expect(AskWebSearchPlugin.engine(of: [:]).title == "Google")
        #expect(AskWebSearchPlugin.engine(of: ["engine": "github"]).template == "https://github.com/search?q={query}")
        #expect(AskWebSearchPlugin.engine(of: ["engine": "baidu"]).title == L("ask.plugin.web.baidu"))
        let own = AskWebSearchPlugin.engine(of: ["engine": "google", "url": "https://en.wikipedia.org/w?search={query}",
                                                "title": "Wiki"])
        #expect(own.title == "Wiki" && own.template == "https://en.wikipedia.org/w?search={query}")
        #expect(AskWebSearchPlugin.engine(of: ["url": "https://duck.com/?q={query}", "title": " "]).title == "duck.com")
        #expect(AskWebSearchPlugin.engine(of: ["engine": "baidu", "url": ""]).title == L("ask.plugin.web.baidu"))
        let url = try #require(AskWebSearchPlugin.url(template: "https://www.google.com/search?q={query}",
                                                      query: "a&b c/d?e#f=g+h 中文"))
        #expect(url.absoluteString
            == "https://www.google.com/search?q=a%26b%20c%2Fd%3Fe%23f%3Dg%2Bh%20%E4%B8%AD%E6%96%87")
        #expect(AskWebSearchPlugin.url(template: "https://example.com/", query: "x") == nil, "no {query}")
        #expect(AskWebSearchPlugin.url(template: "javascript:alert({query})", query: "x") == nil)
        #expect(AskWebSearchPlugin.url(template: "file:///tmp/{query}", query: "x") == nil)
        #expect(AskWebSearchPlugin.url(template: "https:///{query}", query: "x") == nil, "a host is required")
        #expect(AskWebSearchPlugin.problem(with: "https://example.com/") == L("ask.settings.plugins.web.problem.query"))
        #expect(AskWebSearchPlugin.problem(with: "ftp://x.org/{query}") == L("ask.settings.plugins.web.problem.url"))
        #expect(AskWebSearchPlugin.problem(with: " https://x.org/?q={query} ") == nil)
        #expect(AskWebSearchPlugin.host(of: "https://x.org/?q={query}") == "x.org")
    }

    @Test func thePlanOpensTheSearchAndCopiesItsLink() async throws {
        let plugin = AskWebSearchPlugin()
        let plan = await plugin.plan(request("swift\nactors"))
        #expect(plan.mode == .onSubmit)
        #expect(plan.title == L("ask.plugin.web.search", "Google", "swift actors"))
        let link = "https://www.google.com/search?q=swift%20actors"
        #expect(plan.action(for: .enter)?.kind == .open(try #require(URL(string: link))))
        #expect(plan.action(for: .commandC)?.kind == .copy(link))
        #expect(plan.meta == [AskPluginMeta(text: "www.google.com")])
        #expect(plan.action(for: .optionEnter) == nil)
        let broken = await plugin.plan(request(options: ["url": "https://example.com/"]))
        #expect(broken.actions.isEmpty, "a template without {query} offers nothing to open")
        await #expect(throws: AskPluginFailure(message: L("ask.settings.plugins.web.problem.url"), retry: false)) {
            try await plugin.run(request(), plan: broken)
        }
        #expect(plugin.chipDetail(for: AskWebSearchPlugin.keywords[2], language: .english) == "GitHub")
        #expect(plugin.placeholder(selectionLines: nil) == L("ask.plugin.web.placeholder"))
        #expect(plugin.placeholder(selectionLines: 1) == L("ask.plugin.web.placeholder.selection"))
        #expect(plugin.optionName == L("ask.plugin.web.option") && plugin.title == L("ask.plugin.web.title"))
    }

    @Test func tabStepsThroughTheEngines() {
        let plugin = AskWebSearchPlugin()
        let plan = AskPluginPlan(mode: .onSubmit, title: "")
        #expect(plugin.nextOptions(after: plan, request: request(), step: 1)?["engine"] == "baidu")
        #expect(plugin.nextOptions(after: plan, request: request(options: ["engine": "github"]), step: 1)?["engine"] == "google")
        #expect(plugin.nextOptions(after: plan, request: request(), step: -1)?["engine"] == "github")
        let own = request(options: ["url": "https://x.org/?q={query}"])
        #expect(plugin.nextOptions(after: plan, request: own, step: 1) == ["engine": "google", "url": "", "title": ""])
        #expect(plugin.nextOptions(after: plan, request: own, step: -1)?["engine"] == "github")
    }
}

@Suite("Ask plugin registry")
struct AskPluginRegistryTests {
    @Test func pluginsAddedLaterBringTheirKeywords() throws {
        let fyja = AskKeyword(keyword: "fyja", pluginID: "translate", options: ["target": "ja"])
        #expect(AskPluginRegistry.keywords(saved: nil, known: nil) == AskPluginRegistry.defaultKeywords)
        // Saved before the prompt and web plugins existed: they join with their defaults.
        let dict = AskTranslatePlugin.keywords.filter { AskTranslatePlugin.opensWordBook($0.options) }
        #expect(dict.map(\.keyword) == ["dict", "词典"])
        let merged = AskPluginRegistry.keywords(saved: [fyja], known: nil)
        #expect(merged == [fyja] + dict + AskPromptPlugin.keywords + AskWebSearchPlugin.keywords
            + AskFileSearchPlugin.keywords + AskOpenChatPlugin.keywords + AskPrefixPlugin.keywords + AskSettingsPlugin.keywords + AskHistoryPlugin.keywords)
        // Saved before `dict` existed: it joins, and nothing else does.
        #expect(AskPluginRegistry.keywords(saved: [fyja], known: AskPluginRegistry.pluginIDs) == [fyja] + dict)
        // Saved with every group but files: only `f` joins.
        let beforeFiles = AskPluginRegistry.coveredGroups.filter { $0 != AskFileSearchPlugin.id }
        #expect(AskPluginRegistry.keywords(saved: [fyja], known: beforeFiles) == [fyja] + AskFileSearchPlugin.keywords)
        // Saved since: what the user removed stays removed.
        #expect(AskPluginRegistry.keywords(saved: [fyja], known: AskPluginRegistry.coveredGroups) == [fyja])
        #expect(AskPluginRegistry.group(of: dict[0]) == "translate.wordbook")
        #expect(AskPluginRegistry.group(of: fyja) == "translate")
        // A saved keyword already using a default's word wins.
        let mine = AskKeyword(keyword: "G", pluginID: "translate")
        #expect(!AskPluginRegistry.keywords(saved: [mine], known: ["translate"]).contains { $0.pluginID == "web" && $0.keyword == "g" })

        let suite = "ask-registry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.effectiveAskLauncherKeywords == AskPluginRegistry.defaultKeywords)
        settings.askLauncherKeywords = [fyja]
        #expect(settings.effectiveAskLauncherKeywords.count == 14, "an old list gains later plugins and keywords")
        settings.saveAskLauncherKeywords([fyja])
        #expect(settings.askLauncherKeywordPlugins == AskPluginRegistry.coveredGroups)
        #expect(settings.effectiveAskLauncherKeywords == [fyja])
        settings.saveAskLauncherKeywords(nil)
        #expect(settings.askLauncherKeywords == nil && settings.askLauncherKeywordPlugins == nil)
        #expect(AskPluginRegistry.modelName(nil) == "AI")
    }

    @Test func settingsListSetsOptionsAndChecksURLs() {
        var list = AskKeywordList(keywords: AskPluginRegistry.defaultKeywords)
        let g = AskWebSearchPlugin.keywords[0]
        #expect(list.setURL("https://example.com/", on: g) == L("ask.settings.plugins.web.problem.query"))
        #expect(list.keywords(for: "web")[0].options["url"] == nil)
        #expect(list.setURL(" https://x.org/?q={query} ", on: g) == nil)
        #expect(list.keywords(for: "web")[0].options["url"] == "https://x.org/?q={query}")
        let changed = list.keywords(for: "web")[0]
        #expect(list.setURL("", on: changed) == nil)
        #expect(list.keywords(for: "web")[0].options["url"] == nil, "clearing brings the engine back")
        let rw = AskPromptPlugin.keywords[0]
        list.set("prompt", to: "Shorter: {input}", on: rw)
        #expect(list.keywords(for: "prompt")[0].options["prompt"] == "Shorter: {input}")
        list.set("prompt", to: "  ", on: list.keywords(for: "prompt")[0])
        #expect(list.keywords(for: "prompt")[0].options["prompt"] == nil)
        #expect(list.add(pluginID: "prompt").keyword == "rw2")
    }
}
