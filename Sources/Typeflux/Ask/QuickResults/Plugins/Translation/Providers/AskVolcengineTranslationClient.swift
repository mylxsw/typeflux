import Foundation

/// Volcengine machine translation `TranslateText`, signed with Volcengine's HMAC-SHA256 (V4).
struct AskVolcengineTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.volcengine
    let limit = 5000

    static let host = "translate.volcengineapi.com"
    static let service = "translate"
    static let query = "Action=TranslateText&Version=2020-06-01"
    static let contentType = "application/json"

    static let codes = [
        "zh-hans": "zh", "zh-hant": "zh-Hant", "en": "en", "ja": "ja", "ko": "ko", "fr": "fr", "es": "es",
        "de": "de", "ru": "ru", "pt": "pt", "it": "it", "ar": "ar", "th": "th", "vi": "vi", "id": "id", "tr": "tr",
        "nl": "nl", "pl": "pl", "ms": "ms"
    ]

    func code(for language: String) -> String? { AskTranslationLanguages.serviceCode(language, in: Self.codes) }

    /// The `Authorization` header for `payload` sent at `date` ("20260601T120000Z").
    static func authorization(accessKey: String, secretKey: String, region: String, payloadHash: String,
                              date: String) -> String {
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalRequest = [
            "POST", "/", query,
            "content-type:\(contentType)\nhost:\(host)\nx-content-sha256:\(payloadHash)\nx-date:\(date)\n",
            signedHeaders, payloadHash
        ].joined(separator: "\n")
        let day = String(date.prefix(8))
        let scope = "\(day)/\(region)/\(service)/request"
        let stringToSign = ["HMAC-SHA256", date, scope, AskTranslationSigning.sha256Hex(canonicalRequest)]
            .joined(separator: "\n")
        let kDate = AskTranslationSigning.hmac(Data(secretKey.utf8), day)
        let kRegion = AskTranslationSigning.hmac(kDate, region)
        let kService = AskTranslationSigning.hmac(kRegion, service)
        let kSigning = AskTranslationSigning.hmac(kService, "request")
        let signature = AskTranslationSigning.hmacHex(kSigning, stringToSign)
        return "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        var body: [String: Any] = ["TargetLanguage": target, "TextList": [text]]
        if let source { body["SourceLanguage"] = source }
        let payload = try AskTranslationSigning.json(body)
        let payloadHash = AskTranslationSigning.sha256Hex(payload)
        let date = AskTranslationSigning.utc(context.now, "yyyyMMdd'T'HHmmss'Z'")
        var request = URLRequest(url: URL(string: "https://\(Self.host)/?\(Self.query)")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.host, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(date, forHTTPHeaderField: "X-Date")
        request.setValue(Self.authorization(accessKey: credentials.key, secretKey: credentials.secret,
                                            region: credentials.region(for: provider), payloadHash: payloadHash,
                                            date: date), forHTTPHeaderField: "Authorization")
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        let object = AskTranslationSigning.object(data)
        if let error = (object?["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] {
            throw Self.error((error["Code"] as? String) ?? (error["CodeN"] as? Int).map(String.init) ?? "")
        }
        guard status == 200 else { throw AskTranslationServiceError.status(status) }
        guard let list = object?["TranslationList"] as? [[String: Any]], !list.isEmpty else {
            throw AskTranslationServiceError.invalidResponse
        }
        return list.compactMap { $0["Translation"] as? String }.joined(separator: "\n")
    }

    static func error(_ code: String) -> AskTranslationServiceError {
        let lowered = code.lowercased()
        if ["signature", "accesskey", "credential", "authentication", "unauthorized", "forbidden"]
            .contains(where: lowered.contains) { return .authentication }
        if ["flowlimit", "throttl", "ratelimit", "toomanyrequests"].contains(where: lowered.contains) { return .rateLimited }
        if ["overdue", "balance", "quota"].contains(where: lowered.contains) { return .quota }
        if lowered.contains("language") { return .unsupportedLanguage }
        if lowered.contains("toolong") || lowered.contains("length") { return .tooLong }
        return .service(code)
    }
}
