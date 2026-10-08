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
    /// The service's code for a BCP 47 language; nil when it does not translate it.
    func code(for language: String) -> String?
    /// `source` is the service's code, nil to let it detect the language.
    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest
    func translation(from data: Data, status: Int) throws -> String
}

extension AskTranslationProviderClient {
    var limitUnit: AskTranslationTextChunker.Unit { .characters }
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
    static let timeout: TimeInterval = 20

    var provider: AskTranslationProvider { client.provider }

    var isConfigured: Bool { credentials.credentials(for: provider)?.isComplete(for: provider) == true }

    func canTranslate(from source: String?, to target: String) async -> Bool {
        isConfigured && client.code(for: target) != nil
    }

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        guard let keys = credentials.credentials(for: provider), keys.isComplete(for: provider) else {
            throw AskTranslationServiceError.notConfigured
        }
        guard let targetCode = client.code(for: target) else { throw AskTranslationServiceError.unsupportedLanguage }
        // A source the service does not know is left for it to detect.
        let sourceCode = source.flatMap(client.code(for:))
        let pieces = AskTranslationTextChunker.split(text, limit: client.limit, unit: client.limitUnit)
        var translated: [String] = []
        translated.reserveCapacity(pieces.count)
        for piece in pieces {
            guard piece.translates else { translated.append(piece.text); continue }
            try Task.checkCancellation()
            var request = try client.request(piece.text, source: sourceCode, target: targetCode,
                                             credentials: keys.trimmed(), context: context())
            request.timeoutInterval = Self.timeout
            let (data, status) = try await http.send(request)
            translated.append(try client.translation(from: data, status: status))
        }
        // Scripts written without spaces join the parts of a cut line directly.
        let joiner = ["zh", "ja", "ko"].contains(String(AskTranslationLanguages.base(target).prefix(2))) ? "" : " "
        let result = AskTranslationTextChunker.join(pieces, translated, joiner: joiner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AskPluginFailure(message: L("ask.plugin.translate.empty")) }
        return result
    }

    /// Translates "hello" into Chinese with `credentials`, for the settings' connection test.
    func test(_ credentials: AskTranslationCredentials) async throws -> String {
        guard credentials.isComplete(for: provider) else { throw AskTranslationServiceError.notConfigured }
        let store = AskTranslationCredentialOverride(provider: provider, credentials: credentials)
        var engine = self
        engine.credentials = store
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

/// Splits text into pieces a service accepts: runs of lines up to the limit, with
/// blank lines kept apart so they come back unchanged. A line longer than the
/// limit is cut, after a sentence end where it can be.
enum AskTranslationTextChunker {
    enum Unit: Sendable { case characters, utf8Bytes }

    struct Piece: Equatable {
        var text: String
        /// Blank lines are kept as they are rather than sent.
        var translates = true
        /// The rest of the line the piece before ended in, rather than a new line.
        var continuesLine = false
    }

    static func split(_ text: String, limit: Int, unit: Unit) -> [Piece] {
        let limit = max(limit, 1)
        var pieces: [Piece] = []
        var lines: [String] = []
        var size = 0
        func flush() {
            if !lines.isEmpty { pieces.append(Piece(text: lines.joined(separator: "\n"))) }
            lines = []
            size = 0
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                pieces.append(Piece(text: line, translates: false))
                continue
            }
            let length = measure(line, unit)
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
        unit == .characters ? text.count : text.utf8.count
    }

    private static func measure(_ character: Character, _ unit: Unit) -> Int {
        unit == .characters ? 1 : character.utf8.count
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
                if let lastBreak, lastBreak.index < part.count {
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
