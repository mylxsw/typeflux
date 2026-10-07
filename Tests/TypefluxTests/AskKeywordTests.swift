import Foundation
import Testing
@testable import Typeflux

/// A translation engine with a fixed answer, recording what it was asked.
final class AskTestTranslationEngine: AskTranslationEngine, @unchecked Sendable {
    var available: Bool
    var failure: Error?
    var delay: Duration = .zero
    private(set) var requests: [(text: String, source: String?, target: String)] = []

    init(available: Bool = true, failure: Error? = nil) {
        self.available = available
        self.failure = failure
    }

    func canTranslate(from source: String?, to target: String) async -> Bool { available }

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        requests.append((text, source, target))
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return "[\(target)] \(text)"
    }
}

/// Says every text is in one language.
struct AskTestLanguageDetector: AskLanguageDetecting {
    var language: String?
    func detect(_ text: String, hints: [String]) -> String? { language }
}

/// An `LLMService` whose completions are scripted.
final class AskTestLLMService: LLMService, @unchecked Sendable {
    var answer = "Bonjour"
    var failure: Error?
    private(set) var prompts: [(system: String, user: String)] = []

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        prompts.append((systemPrompt, userPrompt))
        if let failure { throw failure }
        return answer
    }

    /// Structured replies, such as word cards.
    var jsonAnswer = "{}"
    private(set) var jsonPrompts: [(system: String, user: String, schema: String)] = []

    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        jsonPrompts.append((systemPrompt, userPrompt, schema.name))
        if let failure { throw failure }
        return jsonAnswer
    }
}

/// A dictionary with a fixed answer, recording what it was asked.
final class AskTestWordLookup: AskWordLookingUp, @unchecked Sendable {
    var answer: AskWordLookup
    private(set) var requests: [(text: String, source: String?, target: String, generation: String)] = []

    init(answer: AskWordLookup) { self.answer = answer }

    func lookUp(_ text: String, from source: String?, to target: String, generation: String) async throws -> AskWordLookup {
        requests.append((text, source, target, generation))
        return answer
    }
}

@Suite("Ask keyword matching")
struct AskKeywordMatcherTests {
    private let keywords = [
        AskKeyword(keyword: "fy", pluginID: "translate"),
        AskKeyword(keyword: "fyja", pluginID: "translate", options: ["target": "ja"]),
        AskKeyword(keyword: "翻译", pluginID: "translate"),
        AskKeyword(keyword: "off", pluginID: "translate", enabled: false)
    ]

    private func match(_ text: String) -> AskKeywordMatcher.Match? { AskKeywordMatcher.match(text, keywords: keywords) }

    @Test(arguments: [
        ("fy hello", "fy", "hello"), ("FY hello", "fy", "hello"), ("fy:hello", "fy", "hello"), ("fy：你好", "fy", "你好"),
        ("fy　你好", "fy", "你好"), ("fy ", "fy", ""), ("fy    spaced", "fy", "spaced"), ("fyja hi", "fyja", "hi"),
        ("翻译 hello", "翻译", "hello"), ("fy line one\nline two", "fy", "line one\nline two")
    ])
    func activatesOnKeywordAndSeparator(text: String, keyword: String, argument: String) {
        guard case let .active(found, found_argument) = match(text) else { Issue.record("no match for \(text)"); return }
        #expect(found.keyword == keyword)
        #expect(found_argument == argument)
    }

    @Test func aLoneKeywordIsOnlyAHint() {
        #expect(match("fy") == .hint(keywords[0]))
        #expect(match("FYJA") == .hint(keywords[1]))
        #expect(match("翻译") == .hint(keywords[2]))
    }

    @Test(arguments: ["fyi what", "f", "", "hello fy", "off text", "off", "fy\nnext", "/fy x"])
    func otherTextIsLeftAlone(text: String) {
        #expect(match(text) == nil, "\(text)")
    }

    @Test func problemsAreNamed() {
        #expect(AskKeywordMatcher.problem(with: "  ", among: keywords) == .empty)
        #expect(AskKeywordMatcher.problem(with: String(repeating: "a", count: 13), among: keywords) == .tooLong)
        #expect(AskKeywordMatcher.problem(with: "a b", among: keywords) == .whitespace)
        #expect(AskKeywordMatcher.problem(with: "a:b", among: keywords) == .whitespace)
        #expect(AskKeywordMatcher.problem(with: "/t", among: keywords) == .slash)
        #expect(AskKeywordMatcher.problem(with: "FY", among: keywords) == .duplicate)
        #expect(AskKeywordMatcher.problem(with: "f", among: keywords) == nil, "a keyword starting another is fine")
        #expect(AskKeywordMatcher.problem(with: "tr", among: keywords) == nil)
        #expect(keywords[0].id == "fy")
    }
}

@Suite("Ask keyword list")
struct AskKeywordListTests {
    @Test func renamesAddsAndRemoves() {
        var list = AskKeywordList(keywords: AskTranslatePlugin.keywords)
        #expect(list.keywords(for: AskTranslatePlugin.id).map(\.keyword) == ["fy", "tr", "翻译", "dict", "词典"])
        let tr = list.keywords[1]
        #expect(list.rename(tr, to: "fy") == .duplicate)
        #expect(list.rename(tr, to: "t r") == .whitespace)
        #expect(list.rename(tr, to: "TR") == nil, "the same word in other case is no change")
        #expect(list.rename(tr, to: " tl ") == nil)
        #expect(list.keywords[1].keyword == "tl")
        #expect(list.rename(AskKeyword(keyword: "gone", pluginID: "x"), to: "new") == nil)
        let added = list.add(pluginID: AskTranslatePlugin.id)
        #expect(added.keyword == "fy2")
        #expect(list.add(pluginID: AskTranslatePlugin.id).keyword == "fy3")
        #expect(list.add(pluginID: "other").keyword == "kw2")
        list.update(added) { $0.options["target"] = "ja"; $0.enabled = false }
        #expect(list.keywords.first { $0.keyword == "fy2" }?.options["target"] == "ja")
        list.remove(list.keywords.first { $0.keyword == "fy2" }!)
        #expect(!list.keywords.contains { $0.keyword == "fy2" })
        for problem in [AskKeywordMatcher.Problem.empty, .tooLong, .whitespace, .slash, .duplicate] {
            #expect(!AskKeywordList.message(for: problem).isEmpty)
        }
    }

    @Test func settingsKeepKeywordsAndSecondLanguage() throws {
        let suite = "ask-keywords-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askLauncherKeywords == nil, "defaults until edited")
        #expect(settings.askTranslationSecondLanguage == nil)
        let custom = [AskKeyword(keyword: "fyja", pluginID: "translate", options: ["target": "ja"])]
        settings.askLauncherKeywords = custom
        #expect(settings.askLauncherKeywords == custom)
        settings.askLauncherKeywords = nil
        #expect(settings.askLauncherKeywords == nil)
        settings.askTranslationSecondLanguage = "ja"
        #expect(settings.askTranslationSecondLanguage == "ja")
        #expect(AskPluginRegistry.defaultKeywords.map(\.keyword)
            == ["fy", "tr", "翻译", "dict", "词典", "rw", "sum", "ex", "g", "bd", "gh", "f", "chat"])
    }
}
