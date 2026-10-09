import Foundation
import Testing
@testable import Typeflux

/// Keys held in memory, so tests never touch the Keychain.
final class AskTestTranslationCredentials: AskTranslationCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AskTranslationProvider: AskTranslationCredentials]
    var refusesSaving = false

    init(_ values: [AskTranslationProvider: AskTranslationCredentials] = [:]) {
        self.values = values
    }

    func credentials(for provider: AskTranslationProvider) -> AskTranslationCredentials? {
        lock.lock(); defer { lock.unlock() }
        return values[provider]
    }

    func save(_ credentials: AskTranslationCredentials, for provider: AskTranslationProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !refusesSaving else { return false }
        values[provider] = credentials
        return true
    }

    func remove(_ provider: AskTranslationProvider) {
        lock.lock(); defer { lock.unlock() }
        values[provider] = nil
    }
}

/// Answers every request with scripted replies, recording what was sent.
final class AskTestTranslationHTTP: AskTranslationHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Data, Int)]
    private(set) var requests: [URLRequest] = []
    var failure: Error?

    init(_ replies: [(String, Int)] = []) {
        self.replies = replies.map { (Data($0.0.utf8), $0.1) }
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        if let failure { throw failure }
        return replies.count > 1 ? replies.removeFirst() : replies.first ?? (Data(), 500)
    }

    var bodies: [[String: Any]] {
        requests.compactMap { $0.httpBody.flatMap(AskTranslationSigning.object) }
    }

    var forms: [[String: String]] {
        requests.compactMap { request in
            guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return nil }
            var fields: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
            }
            return fields
        }
    }
}

private let fixedContext = AskTranslationRequestContext(now: Date(timeIntervalSince1970: 1_700_000_000), salt: "12345678")

private func engine(_ provider: AskTranslationProvider, keys: AskTranslationCredentials? = nil,
                    replies: [(String, Int)]) -> (AskServiceTranslationEngine, AskTestTranslationHTTP) {
    let http = AskTestTranslationHTTP(replies)
    let credentials = AskTestTranslationCredentials(
        [provider: keys ?? AskTranslationCredentials(key: "key", secret: "secret")]
    )
    return (AskServiceTranslationEngine(client: AskServiceTranslationEngine.client(for: provider),
                                        credentials: credentials, http: http, context: { fixedContext }), http)
}

@Suite("Ask translation settings", .exclusiveUIState)
struct AskTranslationSettingsTests {
    private func store() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "AskTranslationSettingsTests-" + UUID().uuidString)!
        return SettingsStore(defaults: defaults)
    }

    @Test func defaultsKeepTheOldBehaviour() {
        let settings = store().askTranslationSettings
        #expect(settings == AskTranslationSettings())
        #expect(settings.engine == .ai && settings.modelReference.isEmpty)
        #expect(settings.prefersOnDevice && settings.fallsBackToAI)
    }

    @Test func savesAndReadsBack() throws {
        let store = store()
        store.askTranslationSettings = AskTranslationSettings(engine: .service(.deepl), modelReference: "custom:x",
                                                              prefersOnDevice: false, fallsBackToAI: false)
        #expect(store.askTranslationSettings.engine == .service(.deepl))
        #expect(store.askTranslationSettings.modelReference == "custom:x")
        #expect(!store.askTranslationSettings.prefersOnDevice && !store.askTranslationSettings.fallsBackToAI)
        // Missing fields read as their defaults; an unknown engine reads as the AI.
        store.defaults.set(Data(#"{"engine":"babel"}"#.utf8), forKey: SettingsStore.askTranslationSettingsKey)
        #expect(store.askTranslationSettings == AskTranslationSettings())
        store.defaults.set(Data("nonsense".utf8), forKey: SettingsStore.askTranslationSettingsKey)
        #expect(store.askTranslationSettings == AskTranslationSettings())
    }

    @Test func engineChoiceRoundTrips() {
        for choice in [AskTranslationEngineChoice.ai] + AskTranslationProvider.allCases.map(AskTranslationEngineChoice.service) {
            #expect(AskTranslationEngineChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(AskTranslationEngineChoice.ai.provider == nil)
        #expect(AskTranslationEngineChoice.service(.baidu).provider == .baidu)
    }

    @Test func translationModelFollowsTheTextModelUntilChosen() throws {
        let store = store()
        #expect(store.translationLLMConfiguration().model == store.textLLMConfiguration().model)
        #expect(store.translationLLMConfiguration().baseURL == store.textLLMConfiguration().baseURL)
        var registry = ModelRegistry()
        registry.providers = [RegisteredProvider(id: "endpoint:x", name: "Mine", baseURL: "https://llm.example/v1",
                                                 models: [RegisteredModel(id: "fast-model", name: "Fast",
                                                                          reference: "custom:fast")])]
        try registry.write(store.defaults)
        store.askTranslationSettings = AskTranslationSettings(modelReference: "custom:fast")
        #expect(store.translationLLMConfiguration().model == "fast-model")
        #expect(store.translationLLMConfiguration().baseURL == "https://llm.example/v1")
        #expect(AskPluginRegistry.translationModelName(store) == "Fast")
        store.askTranslationSettings = AskTranslationSettings(modelReference: "custom:gone")
        #expect(store.translationLLMConfiguration().model.isEmpty, "a removed model is not replaced")
        #expect(AskPluginRegistry.translationModelName(store) == L("ask.models.unavailable"))
        store.askTranslationSettings = AskTranslationSettings(modelReference: "cloud:default")
        #expect(AskPluginRegistry.translationModelName(store) == LLMRemoteProvider.typefluxCloud.displayName)
        registry.providers.append(RegisteredProvider(id: "ollama", name: "Ollama",
                                                     models: [RegisteredModel(id: "qwen3", name: "qwen3",
                                                                              reference: "custom:qwen")]))
        try registry.write(store.defaults)
        store.ollamaBaseURL = "http://127.0.0.1:11434/"
        store.askTranslationSettings = AskTranslationSettings(modelReference: "custom:qwen")
        #expect(store.translationLLMConfiguration().baseURL == "http://127.0.0.1:11434/v1")
        #expect(store.translationLLMConfiguration().model == "qwen3")
        #expect(SettingsStore.ollamaOpenAIBaseURL("") == "http://127.0.0.1:11434/v1")
        #expect(SettingsStore.ollamaOpenAIBaseURL("http://host:1/v1/") == "http://host:1/v1")
        store.askTranslationSettings = AskTranslationSettings()
        #expect(AskPluginRegistry.translationModelName(store) == AskPluginRegistry.modelName(store))
        #expect(AskPluginRegistry.translationModelName(nil) == "AI")
    }

    @Test func providersDescribeTheirFields() {
        for provider in AskTranslationProvider.allCases {
            #expect(!provider.title.isEmpty && !provider.keyLabel.isEmpty && provider.id == provider.rawValue)
        }
        #expect(AskTranslationProvider.deepl.secretLabel == nil && AskTranslationProvider.youdao.secretLabel != nil)
        #expect(AskTranslationProvider.tencent.regionLabel != nil && AskTranslationProvider.deepl.regionLabel == nil)
        #expect(AskTranslationProvider.microsoft.regionLabel != nil)
        #expect(AskTranslationProvider.tencent.defaultRegion == "ap-guangzhou")
        #expect(AskTranslationProvider.volcengine.defaultRegion == "cn-north-1")
    }

    @Test func credentialsNeedEveryRequiredField() {
        #expect(AskTranslationCredentials(key: " k ").isComplete(for: .deepl))
        #expect(!AskTranslationCredentials(key: " ").isComplete(for: .deepl))
        #expect(!AskTranslationCredentials(key: "k").isComplete(for: .youdao))
        #expect(AskTranslationCredentials(key: "k", secret: "s").isComplete(for: .youdao))
        #expect(!AskTranslationCredentials(key: "k\nx", secret: "s").isComplete(for: .youdao))
        #expect(AskTranslationCredentials(key: " k ", secret: " s ", region: " r ").trimmed()
            == AskTranslationCredentials(key: "k", secret: "s", region: "r"))
        #expect(AskTranslationCredentials().region(for: .tencent) == "ap-guangzhou")
        #expect(AskTranslationCredentials(region: "ap-beijing").region(for: .tencent) == "ap-beijing")
        #expect(AskKeychainTranslationCredentials.account(.deepl) == "translation-provider-deepl")
    }

    @Test func keysOverriddenForATest() {
        let override = AskTranslationCredentialOverride(provider: .deepl, credentials: .init(key: "k"))
        #expect(override.credentials(for: .deepl)?.key == "k")
        #expect(override.credentials(for: .google) == nil)
        #expect(!override.save(.init(), for: .deepl))
        override.remove(.deepl)
        #expect(override.credentials(for: .deepl)?.key == "k")
    }
}

@Suite("Ask translation text chunks")
struct AskTranslationTextChunkerTests {
    @Test func shortTextIsOnePiece() {
        let pieces = AskTranslationTextChunker.split("one\ntwo", limit: 100, unit: .characters)
        #expect(pieces == [.init(text: "one\ntwo")])
    }

    @Test func blankLinesStayAndLinesPackUpToTheLimit() {
        let pieces = AskTranslationTextChunker.split("aaaa\nbbbb\n\ncccc", limit: 9, unit: .characters)
        #expect(pieces.map(\.text) == ["aaaa\nbbbb", "", "cccc"])
        #expect(pieces.map(\.translates) == [true, false, true])
        let tight = AskTranslationTextChunker.split("aaaa\nbbbb", limit: 8, unit: .characters)
        #expect(tight.map(\.text) == ["aaaa", "bbbb"])
        #expect(AskTranslationTextChunker.join(tight, ["A", "B"], joiner: " ") == "A\nB")
    }

    @Test func longLinesAreCutAfterSentences() {
        let pieces = AskTranslationTextChunker.split("One two. Three four five.", limit: 12, unit: .characters)
        #expect(pieces.map(\.text) == ["One two.", "Three four", "five."])
        #expect(pieces.map(\.continuesLine) == [false, true, true])
        #expect(AskTranslationTextChunker.join(pieces, ["A.", "B", "C."], joiner: " ") == "A. B C.")
        #expect(AskTranslationTextChunker.join(pieces, ["甲。", "乙", "丙。"], joiner: "") == "甲。乙丙。")
    }

    @Test func bytesCountForMultibyteText() {
        let pieces = AskTranslationTextChunker.split("你好\n世界", limit: 6, unit: .utf8Bytes)
        #expect(pieces.map(\.text) == ["你好", "世界"])
        #expect(AskTranslationTextChunker.measure("你好", .utf8Bytes) == 6)
        #expect(AskTranslationTextChunker.measure("你好", .characters) == 2)
        let cut = AskTranslationTextChunker.split("你好世界", limit: 6, unit: .utf8Bytes)
        #expect(cut.map(\.text) == ["你好", "世界"])
    }
}

@Suite("Ask translation services")
struct AskTranslationServiceTests {
    @Test func signingPrimitives() {
        #expect(AskTranslationSigning.md5Hex("2015063000000001apple143566028812345678") == "f89f9594663708c1605f3d736d01d2d4")
        #expect(AskTranslationSigning.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(AskTranslationSigning.utc(Date(timeIntervalSince1970: 1_700_000_000), "yyyy-MM-dd") == "2023-11-14")
        let form = String(data: AskTranslationSigning.formBody([("q", "a b&c=d+中")]), encoding: .utf8)
        #expect(form == "q=a%20b%26c%3Dd%2B%E4%B8%AD")
    }

    @Test func deepLUsesTheFreeHostForFreeKeys() async throws {
        let (free, http) = engine(.deepl, keys: .init(key: "abc:fx"),
                                  replies: [(#"{"translations":[{"text":"你好"}]}"#, 200)])
        #expect(try await free.translate("Hello", from: "en", to: "zh-Hans") == "你好")
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api-free.deepl.com/v2/translate")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key abc:fx")
        #expect(http.bodies.first?["target_lang"] as? String == "ZH-HANS")
        #expect(http.bodies.first?["source_lang"] as? String == "EN")
        #expect(AskDeepLTranslationClient.host(for: "abc") == "https://api.deepl.com")
        let client = AskDeepLTranslationClient()
        #expect(client.code(for: "en") == "EN-US" && client.code(for: "zh-Hant") == "ZH-HANT" && client.code(for: "xx") == nil)
        #expect(throws: AskTranslationServiceError.quota) { try client.translation(from: Data(), status: 456) }
        #expect(throws: AskTranslationServiceError.authentication) { try client.translation(from: Data(), status: 403) }
        #expect(throws: AskTranslationServiceError.unsupportedLanguage) {
            try client.translation(from: Data(#"{"message":"Value for 'target_lang' not supported."}"#.utf8), status: 400)
        }
        #expect(throws: AskTranslationServiceError.invalidResponse) { try client.translation(from: Data("{}".utf8), status: 200) }
    }

    @Test func googleSendsTheKeyInAHeader() async throws {
        let (google, http) = engine(.google, replies: [(#"{"data":{"translations":[{"translatedText":"你好"}]}}"#, 200)])
        #expect(try await google.translate("Hello", from: "en", to: "zh-Hans") == "你好")
        let request = try #require(http.requests.first)
        #expect(request.url?.query == nil, "the key stays out of the URL")
        #expect(request.value(forHTTPHeaderField: "X-goog-api-key") == "key")
        #expect(http.bodies.first?["target"] as? String == "zh-CN")
        #expect(http.bodies.first?["format"] as? String == "text")
        let client = AskGoogleTranslationClient()
        #expect(client.code(for: "zh-Hant") == "zh-TW" && client.code(for: "ja") == "ja")
        #expect(throws: AskTranslationServiceError.authentication) {
            try client.translation(from: Data(#"{"error":{"message":"API key not valid."}}"#.utf8), status: 400)
        }
        #expect(throws: AskTranslationServiceError.unsupportedLanguage) {
            try client.translation(from: Data(#"{"error":{"message":"Bad language pair"}}"#.utf8), status: 400)
        }
        #expect(throws: AskTranslationServiceError.quota) {
            try client.translation(from: Data(#"{"error":{"message":"Daily Limit Exceeded"}}"#.utf8), status: 403)
        }
        #expect(throws: AskTranslationServiceError.http(500)) { try client.translation(from: Data(), status: 500) }
    }

    @Test func microsoftSendsTheRegionWhenGiven() async throws {
        let reply = #"[{"translations":[{"text":"你好","to":"zh-Hans"}]}]"#
        let (microsoft, http) = engine(.microsoft, keys: .init(key: "k", region: "eastasia"), replies: [(reply, 200)])
        #expect(try await microsoft.translate("Hello", from: "en", to: "zh-Hans") == "你好")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "k")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region") == "eastasia")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "to", value: "zh-Hans")))
        #expect(query.contains(URLQueryItem(name: "from", value: "en")))
        let (global, globalHTTP) = engine(.microsoft, keys: .init(key: "k"), replies: [(reply, 200)])
        _ = try await global.translate("Hello", from: nil, to: "zh-Hans")
        #expect(globalHTTP.requests.first?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region") == nil)
        let client = AskMicrosoftTranslationClient()
        #expect(client.code(for: "zh-TW") == "zh-Hant")
        #expect(throws: AskTranslationServiceError.quota) {
            try client.translation(from: Data(#"{"error":{"code":403001}}"#.utf8), status: 403)
        }
        #expect(throws: AskTranslationServiceError.unsupportedLanguage) {
            try client.translation(from: Data(#"{"error":{"code":400036}}"#.utf8), status: 400)
        }
        #expect(throws: AskTranslationServiceError.authentication) {
            try client.translation(from: Data(#"{"error":{"code":401000}}"#.utf8), status: 401)
        }
        #expect(throws: AskTranslationServiceError.invalidResponse) { try client.translation(from: Data("[]".utf8), status: 200) }
    }

    @Test func youdaoSignsWithV3() async throws {
        #expect(AskYoudaoTranslationClient.sign(appKey: "app", text: "hello", salt: "12345678", time: "1700000000",
                                                secret: "sec")
            == "ade6ffba94f8eba958b3208b71916d16515894456e45a368fea34607d2d455d8")
        #expect(AskYoudaoTranslationClient.signedInput("abcdefghijklmnopqrstuvwxyz") == "abcdefghij26qrstuvwxyz")
        #expect(AskYoudaoTranslationClient.signedInput("short") == "short")
        let (youdao, http) = engine(.youdao, keys: .init(key: "app", secret: "sec"),
                                    replies: [(#"{"errorCode":"0","translation":["你好"]}"#, 200)])
        #expect(try await youdao.translate("hello", from: "en", to: "zh-Hans") == "你好")
        let form = try #require(http.forms.first)
        #expect(form["from"] == "en" && form["to"] == "zh-CHS" && form["signType"] == "v3")
        #expect(form["curtime"] == "1700000000" && form["salt"] == "12345678")
        #expect(form["sign"] == "ade6ffba94f8eba958b3208b71916d16515894456e45a368fea34607d2d455d8")
        let client = AskYoudaoTranslationClient()
        #expect(throws: AskTranslationServiceError.authentication) {
            try client.translation(from: Data(#"{"errorCode":"108"}"#.utf8), status: 200)
        }
        #expect(throws: AskTranslationServiceError.quota) {
            try client.translation(from: Data(#"{"errorCode":"401"}"#.utf8), status: 200)
        }
        #expect(AskYoudaoTranslationClient.error("102") == .unsupportedLanguage)
        #expect(AskYoudaoTranslationClient.error("103") == .tooLong)
        #expect(AskYoudaoTranslationClient.error("411") == .rateLimited)
        #expect(AskYoudaoTranslationClient.error("999") == .service("999"))
        #expect(throws: AskTranslationServiceError.invalidResponse) {
            try client.translation(from: Data(#"{"errorCode":"0"}"#.utf8), status: 200)
        }
    }

    @Test func baiduSignsWithMD5AndJoinsLines() async throws {
        #expect(AskBaiduTranslationClient.sign(appID: "2015063000000001", text: "apple", salt: "1435660288",
                                               secret: "12345678") == "f89f9594663708c1605f3d736d01d2d4")
        let reply = #"{"from":"en","to":"zh","trans_result":[{"src":"one","dst":"一"},{"src":"two","dst":"二"}]}"#
        let (baidu, http) = engine(.baidu, replies: [(reply, 200)])
        #expect(try await baidu.translate("one\ntwo", from: nil, to: "ja") == "一\n二")
        let form = try #require(http.forms.first)
        #expect(form["from"] == "auto" && form["to"] == "jp" && form["appid"] == "key")
        #expect(form["sign"] == AskBaiduTranslationClient.sign(appID: "key", text: "one\ntwo", salt: "12345678",
                                                                secret: "secret"))
        let client = AskBaiduTranslationClient()
        #expect(throws: AskTranslationServiceError.authentication) {
            try client.translation(from: Data(#"{"error_code":"54001"}"#.utf8), status: 200)
        }
        #expect(AskBaiduTranslationClient.error("54004") == .quota)
        #expect(AskBaiduTranslationClient.error("54003") == .rateLimited)
        #expect(AskBaiduTranslationClient.error("58001") == .unsupportedLanguage)
        #expect(AskBaiduTranslationClient.error("52001") == .service("52001"))
        #expect(throws: AskTranslationServiceError.invalidResponse) { try client.translation(from: Data("{}".utf8), status: 200) }
    }

    @Test func tencentSignsWithTC3() async throws {
        let payload = Data(#"{"ProjectId":0,"Source":"en","SourceText":"hello","Target":"zh"}"#.utf8)
        let authorization = AskTencentTranslationClient.authorization(secretID: "id", secretKey: "secretKey",
                                                                      payload: payload, timestamp: 1_700_000_000)
        #expect(authorization == "TC3-HMAC-SHA256 Credential=id/2023-11-14/tmt/tc3_request, "
            + "SignedHeaders=content-type;host;x-tc-action, "
            + "Signature=029ad1245e4f255f7566d21144ecdb552088bb5f5e270c9fad3acd335a064b40")
        let (tencent, http) = engine(.tencent, keys: .init(key: "id", secret: "secretKey"),
                                     replies: [(#"{"Response":{"TargetText":"你好","RequestId":"r"}}"#, 200)])
        #expect(try await tencent.translate("hello", from: "en", to: "zh-Hans") == "你好")
        let request = try #require(http.requests.first)
        #expect(request.httpBody == payload)
        #expect(request.value(forHTTPHeaderField: "Authorization") == authorization)
        #expect(request.value(forHTTPHeaderField: "X-TC-Region") == "ap-guangzhou")
        #expect(request.value(forHTTPHeaderField: "X-TC-Timestamp") == "1700000000")
        let client = AskTencentTranslationClient()
        #expect(throws: AskTranslationServiceError.authentication) {
            try client.translation(from: Data(#"{"Response":{"Error":{"Code":"AuthFailure.SignatureFailure"}}}"#.utf8),
                                   status: 200)
        }
        #expect(AskTencentTranslationClient.error("FailedOperation.NoFreeAmount") == .quota)
        #expect(AskTencentTranslationClient.error("RequestLimitExceeded") == .rateLimited)
        #expect(AskTencentTranslationClient.error("UnsupportedOperation.UnsupportedLanguage") == .unsupportedLanguage)
        #expect(AskTencentTranslationClient.error("UnsupportedOperation.TextTooLong") == .tooLong)
        #expect(AskTencentTranslationClient.error("InternalError") == .service("InternalError"))
        #expect(throws: AskTranslationServiceError.invalidResponse) { try client.translation(from: Data("{}".utf8), status: 200) }
    }

    @Test func volcengineSignsWithV4() async throws {
        let hash = "ec34e229017f20f239759878539e5b43802ac45d2329c4b7b0d9439e0ef8b7af"
        let authorization = AskVolcengineTranslationClient.authorization(
            accessKey: "ak", secretKey: "secretKey", region: "cn-north-1", payloadHash: hash, date: "20231114T221320Z"
        )
        #expect(authorization == "HMAC-SHA256 Credential=ak/20231114/cn-north-1/translate/request, "
            + "SignedHeaders=content-type;host;x-content-sha256;x-date, "
            + "Signature=4c2981ffcfd8f3a31b0fed3fc058758b19eead2e28be0733b1a9b86a6949c88e")
        let (volcengine, http) = engine(.volcengine, keys: .init(key: "ak", secret: "secretKey"),
                                        replies: [(#"{"TranslationList":[{"Translation":"你好"}]}"#, 200)])
        #expect(try await volcengine.translate("hello", from: "en", to: "zh-Hans") == "你好")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Content-Sha256") == hash)
        #expect(request.value(forHTTPHeaderField: "X-Date") == "20231114T221320Z")
        #expect(request.value(forHTTPHeaderField: "Authorization") == authorization)
        #expect(request.url?.query == "Action=TranslateText&Version=2020-06-01")
        let client = AskVolcengineTranslationClient()
        #expect(throws: AskTranslationServiceError.authentication) {
            try client.translation(from: Data(#"{"ResponseMetadata":{"Error":{"Code":"SignatureDoesNotMatch"}}}"#.utf8),
                                   status: 401)
        }
        #expect(AskVolcengineTranslationClient.error("FlowLimitExceeded") == .rateLimited)
        #expect(AskVolcengineTranslationClient.error("AccountOverdue") == .quota)
        #expect(AskVolcengineTranslationClient.error("-415 UnsupportedLanguage") == .unsupportedLanguage)
        #expect(AskVolcengineTranslationClient.error("TextTooLong") == .tooLong)
        #expect(AskVolcengineTranslationClient.error("Oops") == .service("Oops"))
        #expect(throws: AskTranslationServiceError.http(502)) { try client.translation(from: Data(), status: 502) }
        #expect(throws: AskTranslationServiceError.invalidResponse) { try client.translation(from: Data("{}".utf8), status: 200) }
    }

    @Test func theEngineChecksKeysAndLanguages() async throws {
        let http = AskTestTranslationHTTP()
        let missing = AskServiceTranslationEngine(client: AskDeepLTranslationClient(),
                                                  credentials: AskTestTranslationCredentials(), http: http)
        #expect(!missing.isConfigured)
        #expect(await missing.canTranslate(from: "en", to: "zh-Hans") == false)
        await #expect(throws: AskTranslationServiceError.notConfigured) {
            try await missing.translate("Hi", from: "en", to: "zh-Hans")
        }
        let (deepl, _) = engine(.deepl, replies: [])
        #expect(deepl.isConfigured && deepl.provider == .deepl)
        #expect(await deepl.canTranslate(from: "en", to: "zh-Hans"))
        #expect(await deepl.canTranslate(from: "en", to: "xx") == false)
        await #expect(throws: AskTranslationServiceError.unsupportedLanguage) {
            try await deepl.translate("Hi", from: "en", to: "xx")
        }
        for provider in AskTranslationProvider.allCases {
            #expect(AskServiceTranslationEngine.client(for: provider).provider == provider)
        }
    }

    @Test func theEngineTranslatesLongTextInPiecesAndKeepsBlankLines() async throws {
        let (google, http) = engine(.google, replies: [
            (#"{"data":{"translations":[{"translatedText":"A"}]}}"#, 200),
            (#"{"data":{"translations":[{"translatedText":"B"}]}}"#, 200)
        ])
        let text = String(repeating: "x", count: 4000) + "\n\n" + String(repeating: "y", count: 4000)
        #expect(try await google.translate(text, from: "en", to: "fr") == "A\n\nB")
        #expect(http.requests.count == 2)
        let (empty, _) = engine(.google, replies: [(#"{"data":{"translations":[{"translatedText":"  "}]}}"#, 200)])
        await #expect(throws: AskPluginFailure.self) { try await empty.translate("Hi", from: nil, to: "fr") }
        let (failing, failingHTTP) = engine(.google, replies: [])
        failingHTTP.failure = URLError(.notConnectedToInternet)
        await #expect(throws: URLError.self) { try await failing.translate("Hi", from: nil, to: "fr") }
    }

    @Test func connectionTestsUseTheKeysBeingEdited() async throws {
        let (deepl, http) = engine(.deepl, replies: [(#"{"translations":[{"text":"你好"}]}"#, 200)])
        #expect(try await deepl.test(.init(key: "new:fx")) == "你好")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key new:fx")
        await #expect(throws: AskTranslationServiceError.notConfigured) { try await deepl.test(.init()) }
    }

    @Test func errorsReadWithoutKeys() {
        let errors: [AskTranslationServiceError] = [.notConfigured, .unsupportedLanguage, .authentication, .quota,
                                                    .rateLimited, .tooLong, .invalidResponse, .service("E1"), .http(502)]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(AskTranslationServiceError.service("E1").errorDescription?.contains("E1") == true)
        #expect(AskTranslationServiceError.status(401) == .authentication)
        #expect(AskTranslationServiceError.status(413) == .tooLong)
        #expect(AskTranslationServiceError.status(429) == .rateLimited)
        #expect(AskTranslationServiceError.status(456) == .quota)
        #expect(AskTranslationServiceError.status(500) == .http(500))
    }
}
