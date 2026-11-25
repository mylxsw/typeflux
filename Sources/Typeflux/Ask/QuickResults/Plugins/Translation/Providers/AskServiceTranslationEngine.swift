import Foundation

/// Why a translation service did not translate. Messages never carry the keys.
enum AskTranslationServiceError: Error, Equatable, LocalizedError {
    case notConfigured
    case unsupportedLanguage
    case authentication
    case quota
    case rateLimited
    case tooLong
    case invalidResponse
    /// The service's own error code, for anything not sorted above.
    case service(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L("ask.translation.error.notConfigured")
        case .unsupportedLanguage: L("ask.translation.error.unsupportedLanguage")
        case .authentication: L("ask.translation.error.authentication")
        case .quota: L("ask.translation.error.quota")
        case .rateLimited: L("ask.translation.error.rateLimited")
        case .tooLong: L("ask.translation.error.tooLong")
        case .invalidResponse: L("ask.translation.error.invalidResponse")
        case let .service(code): L("ask.translation.error.service", code)
        case let .http(status): L("ask.translation.error.http", status)
        }
    }

    /// The usual meaning of an HTTP status from a translation API.
    static func status(_ status: Int) -> Self {
        switch status {
        case 401, 403: .authentication
        case 413: .tooLong
        case 429: .rateLimited
        case 456: .quota
        default: .http(status)
        }
    }
}

/// One request's worth of a service's API: how to ask, and how to read the answer.
protocol AskTranslationProviderClient: Sendable {
    var provider: AskTranslationProvider { get }
    /// The most one request carries, counted in `limitUnit`.
    var limit: Int { get }
    var limitUnit: AskTranslationTextChunker.Unit { get }
    /// Whether the service accepts blank lines inside a single request.
    var sendsBlankLines: Bool { get }
    var rateLimitRetryDelay: Duration? { get }
    /// The service's code for a BCP 47 language; nil when it does not translate it.
    func code(for language: String) -> String?
    /// `source` is the service's code, nil to let it detect the language.
    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest
    func translation(from data: Data, status: Int) throws -> String
}

extension AskTranslationProviderClient {
    var limitUnit: AskTranslationTextChunker.Unit { .characters }
    var sendsBlankLines: Bool { false }
    var rateLimitRetryDelay: Duration? { nil }
}

/// The clock and the random salt a signed request uses; tests fix both.
struct AskTranslationRequestContext: Sendable {
    var now: Date
    var salt: String

    static func live() -> Self { .init(now: Date(), salt: String(Int.random(in: 10_000_000 ... 99_999_999))) }
}

/// Sends a request; tests answer it without the network.
protocol AskTranslationHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct AskURLSessionTranslationHTTP: AskTranslationHTTP {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Translation by a service, with the keys from the Keychain: long text goes
/// in pieces that fit the service, and blank lines stay where they were.
struct AskServiceTranslationEngine: AskTranslationEngine {
    let client: any AskTranslationProviderClient
    var credentials: any AskTranslationCredentialStoring = AskKeychainTranslationCredentials()
    var http: any AskTranslationHTTP = AskURLSessionTranslationHTTP()
    var context: @Sendable () -> AskTranslationRequestContext = { .live() }
    var cache: AskTranslationCache?
    static let timeout: TimeInterval = 20

    var provider: AskTranslationProvider { client.provider }

    var isConfigured: Bool { credentials.credentials(for: provider)?.isComplete(for: provider) == true }

    func canTranslate(from source: String?, to target: String) async -> Bool {
        isConfigured && client.code(for: target) != nil
    }

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        guard let keys = credentials.credentials(for: provider)?.trimmed(), keys.isComplete(for: provider) else {
            throw AskTranslationServiceError.notConfigured
        }
        guard let targetCode = client.code(for: target) else { throw AskTranslationServiceError.unsupportedLanguage }
        // A source the service does not know is left for it to detect.
        let sourceCode = source.flatMap(client.code(for:))
        let pieces = AskTranslationTextChunker.split(text, limit: client.limit, unit: client.limitUnit,
                                                     sendsBlankLines: client.sendsBlankLines)
        var translated: [String] = []
        translated.reserveCapacity(pieces.count)
        for piece in pieces {
            guard piece.translates else { translated.append(piece.text); continue }
            try Task.checkCancellation()
            guard AskTranslationTextChunker.measure(piece.text, client.limitUnit) <= client.limit else {
                throw AskTranslationServiceError.tooLong
            }
            let fetch = {
                try await translatePiece(piece.text, source: sourceCode, target: targetCode, credentials: keys)
            }
            if let cache {
                let key = AskTranslationCache.key(provider: provider, text: piece.text, source: sourceCode,
                                                  target: targetCode, credentials: keys)
                translated.append(try await cache.translation(for: key, fetch: fetch))
            } else {
                translated.append(try await fetch())
            }
        }
        // Scripts written without spaces join the parts of a cut line directly.
        let joiner = ["zh", "ja", "ko"].contains(String(AskTranslationLanguages.base(target).prefix(2))) ? "" : " "
        let result = AskTranslationTextChunker.join(pieces, translated, joiner: joiner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AskPluginFailure(message: L("ask.plugin.translate.empty")) }
        return result
    }

    private func translatePiece(_ text: String, source: String?, target: String,
                                credentials: AskTranslationCredentials) async throws -> String {
        do {
            return try await requestTranslation(text, source: source, target: target, credentials: credentials)
        } catch AskTranslationServiceError.rateLimited {
            guard let delay = client.rateLimitRetryDelay else { throw AskTranslationServiceError.rateLimited }
            try await Task.sleep(for: delay)
            return try await requestTranslation(text, source: source, target: target, credentials: credentials)
        }
    }

    private func requestTranslation(_ text: String, source: String?, target: String,
                                    credentials: AskTranslationCredentials) async throws -> String {
        var request = try client.request(text, source: source, target: target, credentials: credentials, context: context())
        request.timeoutInterval = Self.timeout
        let (data, status) = try await http.send(request)
        return try client.translation(from: data, status: status)
    }

    /// Translates "hello" into Chinese with `credentials`, for the settings' connection test.
    func test(_ credentials: AskTranslationCredentials) async throws -> String {
        guard credentials.isComplete(for: provider) else { throw AskTranslationServiceError.notConfigured }
        let store = AskTranslationCredentialOverride(provider: provider, credentials: credentials)
        var engine = self
        engine.credentials = store
        engine.cache = nil
        return try await engine.translate("hello", from: "en", to: "zh-Hans")
    }

    /// The services this Mac can use, configured or not.
    static func client(for provider: AskTranslationProvider) -> any AskTranslationProviderClient {
        switch provider {
        case .deepl: AskDeepLTranslationClient()
        case .google: AskGoogleTranslationClient()
        case .microsoft: AskMicrosoftTranslationClient()
        case .youdao: AskYoudaoTranslationClient()
        case .baidu: AskBaiduTranslationClient()
        case .tencent: AskTencentTranslationClient()
        case .volcengine: AskVolcengineTranslationClient()
        }
    }
}

/// Keys being tested before they are saved.
struct AskTranslationCredentialOverride: AskTranslationCredentialStoring {
    let provider: AskTranslationProvider
    let credentials: AskTranslationCredentials

    func credentials(for provider: AskTranslationProvider) -> AskTranslationCredentials? {
        provider == self.provider ? credentials : nil
    }

    func save(_ credentials: AskTranslationCredentials, for provider: AskTranslationProvider) -> Bool { false }
    func remove(_ provider: AskTranslationProvider) {}
}

/// Splits text into runs of lines up to the service limit. Blank lines outside
/// a request are kept locally. Long lines are cut at sentence ends when possible.
enum AskTranslationTextChunker {
    enum Unit: Sendable { case characters, unicodeScalars, utf8Bytes }

    struct Piece: Equatable {
        var text: String
        /// Blank lines are kept as they are rather than sent.
        var translates = true
        /// The rest of the line the piece before ended in, rather than a new line.
        var continuesLine = false
    }

    static func split(_ text: String, limit: Int, unit: Unit, sendsBlankLines: Bool = false) -> [Piece] {
        let limit = max(limit, 1)
        var pieces: [Piece] = []
        var lines: [String] = []
        var size = 0
        func isBlank(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func flush() {
            let first = lines.firstIndex { !isBlank($0) } ?? lines.endIndex
            let end = lines.lastIndex { !isBlank($0) }.map { $0 + 1 } ?? lines.endIndex
            pieces += lines[..<first].map { Piece(text: $0, translates: false) }
            if first < end {
                pieces.append(Piece(text: lines[first..<end].joined(separator: "\n")))
            }
            pieces += lines[end...].map { Piece(text: $0, translates: false) }
            lines = []
            size = 0
        }
        for line in text.components(separatedBy: "\n") {
            let length = measure(line, unit)
            if (!sendsBlankLines || length > limit) && isBlank(line) {
                flush()
                pieces.append(Piece(text: line, translates: false))
                continue
            }
            if length > limit {
                flush()
                for (index, part) in cut(line, limit: limit, unit: unit).enumerated() {
                    pieces.append(Piece(text: part, continuesLine: index > 0))
                }
                continue
            }
            if !lines.isEmpty, size + 1 + length > limit { flush() }
            size += (lines.isEmpty ? 0 : 1) + length
            lines.append(line)
        }
        flush()
        return pieces
    }

    /// Puts translated pieces back together: lines on new lines, the parts of a cut
    /// line joined by `joiner`.
    static func join(_ pieces: [Piece], _ texts: [String], joiner: String) -> String {
        var result = ""
        for (index, piece) in pieces.enumerated() where index < texts.count {
            if index > 0 { result += piece.continuesLine ? joiner : "\n" }
            result += texts[index]
        }
        return result
    }

    static func measure(_ text: String, _ unit: Unit) -> Int {
        switch unit {
        case .characters: text.count
        case .unicodeScalars: text.unicodeScalars.count
        case .utf8Bytes: text.utf8.count
        }
    }

    private static func measure(_ character: Character, _ unit: Unit) -> Int {
        switch unit {
        case .characters: 1
        case .unicodeScalars: character.unicodeScalars.count
        case .utf8Bytes: character.utf8.count
        }
    }

    private static func cut(_ line: String, limit: Int, unit: Unit) -> [String] {
        var parts: [String] = []
        var part: [Character] = []
        var size = 0
        /// Where the last sentence in `part` ended, and the size up to there.
        var lastBreak: (index: Int, size: Int)?
        for character in line {
            let length = measure(character, unit)
            if size + length > limit, !part.isEmpty {
                if let lastBreak, lastBreak.index < part.count, size - lastBreak.size + length <= limit {
                    parts.append(String(part[..<lastBreak.index]))
                    part = Array(part[lastBreak.index...])
                    size -= lastBreak.size
                } else {
                    parts.append(String(part))
                    part = []
                    size = 0
                }
                lastBreak = nil
            }
            part.append(character)
            size += length
            if ".!?。！？；;".contains(character) { lastBreak = (part.count, size) }
        }
        if !part.isEmpty { parts.append(String(part)) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
