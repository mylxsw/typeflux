import Foundation

/// Baidu general text translation, signed with MD5 of the app ID, text, salt and key.
struct AskBaiduTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.baidu
    // Baidu takes up to 6,000 bytes.
    let limit = 5000
    let limitUnit = AskTranslationTextChunker.Unit.utf8Bytes

    static let codes = [
        "zh-hans": "zh", "zh-hant": "cht", "en": "en", "ja": "jp", "ko": "kor", "fr": "fra", "de": "de",
        "es": "spa", "ru": "ru", "pt": "pt", "it": "it", "ar": "ara", "nl": "nl", "th": "th", "vi": "vie",
        "el": "el", "pl": "pl", "sv": "swe", "da": "dan", "fi": "fin", "cs": "cs", "ro": "rom", "hu": "hu",
        "bg": "bul", "et": "est", "sl": "slo"
    ]

    func code(for language: String) -> String? { AskTranslationLanguages.serviceCode(language, in: Self.codes) }

    static func sign(appID: String, text: String, salt: String, secret: String) -> String {
        AskTranslationSigning.md5Hex(appID + text + salt + secret)
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = AskTranslationSigning.formBody([
            ("q", text), ("from", source ?? "auto"), ("to", target), ("appid", credentials.key),
            ("salt", context.salt),
            ("sign", Self.sign(appID: credentials.key, text: text, salt: context.salt, secret: credentials.secret))
        ])
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        guard status == 200 else { throw AskTranslationServiceError.status(status) }
        guard let object = AskTranslationSigning.object(data) else { throw AskTranslationServiceError.invalidResponse }
        if let code = (object["error_code"] as? String) ?? (object["error_code"] as? Int).map(String.init),
           code != "52000" {
            throw Self.error(code)
        }
        // One result per line of the request.
        guard let results = object["trans_result"] as? [[String: Any]], !results.isEmpty else {
            throw AskTranslationServiceError.invalidResponse
        }
        return results.compactMap { $0["dst"] as? String }.joined(separator: "\n")
    }

    static func error(_ code: String) -> AskTranslationServiceError {
        switch code {
        case "52003", "54001", "58000", "58002", "90107": .authentication
        case "54003", "54005": .rateLimited
        case "54004": .quota
        case "58001": .unsupportedLanguage
        default: .service(code)
        }
    }
}
