import Foundation

/// Tencent Cloud machine translation (TMT) `TextTranslate`, signed with TC3-HMAC-SHA256.
struct AskTencentTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.tencent
    // Each request takes under 6,000 characters.
    let limit = 5000

    static let host = "tmt.tencentcloudapi.com"
    static let service = "tmt"
    static let action = "TextTranslate"
    static let version = "2018-03-21"
    static let contentType = "application/json; charset=utf-8"

    static let codes = [
        "zh-hans": "zh", "zh-hant": "zh-TW", "en": "en", "ja": "ja", "ko": "ko", "fr": "fr", "es": "es", "it": "it",
        "de": "de", "tr": "tr", "ru": "ru", "pt": "pt", "vi": "vi", "id": "id", "th": "th", "ms": "ms", "ar": "ar",
        "hi": "hi"
    ]

    func code(for language: String) -> String? { AskTranslationLanguages.serviceCode(language, in: Self.codes) }

    /// The `Authorization` header for `payload` sent at `timestamp`.
    static func authorization(secretID: String, secretKey: String, payload: Data, timestamp: Int) -> String {
        let date = AskTranslationSigning.utc(Date(timeIntervalSince1970: TimeInterval(timestamp)), "yyyy-MM-dd")
        let signedHeaders = "content-type;host;x-tc-action"
        let canonicalRequest = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(host)\nx-tc-action:\(action.lowercased())\n",
            signedHeaders, AskTranslationSigning.sha256Hex(payload)
        ].joined(separator: "\n")
        let scope = "\(date)/\(service)/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", String(timestamp), scope,
                            AskTranslationSigning.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let secretDate = AskTranslationSigning.hmac(Data(("TC3" + secretKey).utf8), date)
        let secretService = AskTranslationSigning.hmac(secretDate, service)
        let secretSigning = AskTranslationSigning.hmac(secretService, "tc3_request")
        let signature = AskTranslationSigning.hmacHex(secretSigning, stringToSign)
        return "TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        let timestamp = Int(context.now.timeIntervalSince1970)
        let payload = try AskTranslationSigning.json([
            "SourceText": text, "Source": source ?? "auto", "Target": target, "ProjectId": 0
        ] as [String: Any])
        var request = URLRequest(url: URL(string: "https://\(Self.host)")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.host, forHTTPHeaderField: "Host")
        request.setValue(Self.action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(Self.version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(credentials.region(for: provider), forHTTPHeaderField: "X-TC-Region")
        request.setValue(Self.authorization(secretID: credentials.key, secretKey: credentials.secret, payload: payload,
                                            timestamp: timestamp), forHTTPHeaderField: "Authorization")
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        guard status == 200 else { throw AskTranslationServiceError.status(status) }
        guard let response = AskTranslationSigning.object(data)?["Response"] as? [String: Any] else {
            throw AskTranslationServiceError.invalidResponse
        }
        if let error = response["Error"] as? [String: Any] { throw Self.error(error["Code"] as? String ?? "") }
        guard let text = response["TargetText"] as? String else { throw AskTranslationServiceError.invalidResponse }
        return text
    }

    static func error(_ code: String) -> AskTranslationServiceError {
        if code.hasPrefix("AuthFailure") || code == "FailedOperation.UserNotRegistered" { return .authentication }
        if code.hasPrefix("RequestLimitExceeded") || code == "LimitExceeded" { return .rateLimited }
        if ["FailedOperation.NoFreeAmount", "FailedOperation.ServiceIsolate"].contains(code) { return .quota }
        if code.hasPrefix("UnsupportedOperation.Unsupported") && code.contains("Language") { return .unsupportedLanguage }
        if code == "UnsupportedOperation.TextTooLong" { return .tooLong }
        return .service(code)
    }
}
