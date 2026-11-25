import Foundation
import Testing
@testable import Typeflux

@Suite("External translation cache", .exclusiveUIState)
struct AskTranslationCacheTests {
    private let credentials = AskTranslationCredentials(key: "app", secret: "secret")

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func youdao(cache: AskTranslationCache, http: any AskTranslationHTTP) -> AskServiceTranslationEngine {
        AskServiceTranslationEngine(client: AskYoudaoTranslationClient(),
                                    credentials: AskTestTranslationCredentials([.youdao: credentials]),
                                    http: http, cache: cache)
    }

    @Test func youdaoSendsSixParagraphsTogetherAndReopensItsCachedTranslation() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = [108, 389, 253, 650, 320, 146].map { String(repeating: "x", count: $0) }.joined(separator: "\n\n")
        let firstHTTP = AskTestTranslationHTTP([(#"{"errorCode":"0","translation":["第一段\n\n第二段"]}"#, 200)])
        let first = youdao(cache: .init(directory: directory), http: firstHTTP)
        let expected = "第一段\n\n第二段"
        #expect(try await first.translate(text, from: "en", to: "zh-Hans") == expected)
        #expect(firstHTTP.forms.compactMap { $0["q"] } == [text])

        let offlineHTTP = AskTestTranslationHTTP()
        offlineHTTP.failure = URLError(.notConnectedToInternet)
        let reopened = youdao(cache: .init(directory: directory), http: offlineHTTP)
        #expect(try await reopened.translate(text, from: "en", to: "zh-Hans") == expected)
        #expect(offlineHTTP.requests.isEmpty)
    }

    @Test func cacheKeysSeparateProvidersLanguagesTextAndCredentials() {
        func key(_ provider: AskTranslationProvider = .youdao, text: String = "hello", source: String? = "en",
                 target: String = "zh-CHS", credentials: AskTranslationCredentials? = nil) -> String {
            AskTranslationCache.key(provider: provider, text: text, source: source, target: target,
                                    credentials: credentials ?? self.credentials)
        }
        let keys = [key(), key(.google), key(text: "Hello"), key(source: nil), key(target: "ja"),
                    key(credentials: .init(key: "another", secret: "secret")),
                    key(credentials: .init(key: "app", secret: "rotated")),
                    key(credentials: .init(key: "app", secret: "secret", region: "west"))]
        #expect(Set(keys).count == keys.count)
    }

    @Test func matchingInFlightRequestsShareOneAPICall() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = SlowTranslationHTTP()
        let first = youdao(cache: .init(directory: directory), http: http)
        let second = youdao(cache: .init(directory: directory), http: http)
        async let firstAnswer = first.translate("Same request", from: "en", to: "zh-Hans")
        async let secondAnswer = second.translate("Same request", from: "en", to: "zh-Hans")
        let answers = try await [firstAnswer, secondAnswer]
        #expect(answers == ["译文", "译文"])
        #expect(await http.calls == 1)
    }

    @Test func retryReusesSuccessfulChunksAndDoesNotCacheRateLimitErrors() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = String(repeating: "x", count: 4999)
        let second = "Next paragraph"
        let text = first + "\n\n" + second
        let http = AskTestTranslationHTTP([
            (#"{"errorCode":"0","translation":["甲"]}"#, 200),
            (#"{"errorCode":"411"}"#, 200),
            (#"{"errorCode":"411"}"#, 200),
            (#"{"errorCode":"0","translation":["乙"]}"#, 200)
        ])
        let engine = youdao(cache: .init(directory: directory), http: http)
        await #expect(throws: AskTranslationServiceError.rateLimited) {
            try await engine.translate(text, from: "en", to: "zh-Hans")
        }
        #expect(try await engine.translate(text, from: "en", to: "zh-Hans") == "甲\n\n乙")
        #expect(try await engine.translate(text, from: "en", to: "zh-Hans") == "甲\n\n乙")
        #expect(http.forms.compactMap { $0["q"] } == [first, second, second, second])
    }

    @Test func connectionTestChecksTheLiveServiceEvenWhenHelloIsCached() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = AskTestTranslationHTTP([
            (#"{"errorCode":"0","translation":["缓存"]}"#, 200),
            (#"{"errorCode":"0","translation":["实时"]}"#, 200)
        ])
        let engine = youdao(cache: .init(directory: directory), http: http)
        #expect(try await engine.translate("hello", from: "en", to: "zh-Hans") == "缓存")
        #expect(try await engine.test(credentials) == "实时")
        #expect(try await engine.translate("hello", from: "en", to: "zh-Hans") == "缓存")
        #expect(http.requests.count == 2)
    }
}

private actor SlowTranslationHTTP: AskTranslationHTTP {
    private(set) var calls = 0

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(for: .milliseconds(150))
        return (Data(#"{"errorCode":"0","translation":["译文"]}"#.utf8), 200)
    }
}
