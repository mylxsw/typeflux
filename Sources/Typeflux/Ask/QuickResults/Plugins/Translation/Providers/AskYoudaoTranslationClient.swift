import Foundation

/// Youdao AI cloud text translation, signed with v3 (SHA-256).
struct AskYoudaoTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.youdao
    let limit = 5000

    static let codes = [
        "zh-hans": "zh-CHS", "zh-hant": "zh-CHT", "en": "en", "ja": "ja", "ko": "ko", "fr": "fr", "de": "de",
        "es": "es", "ru": "ru", "pt": "pt", "it": "it", "ar": "ar", "nl": "nl", "th": "th", "vi": "vi", "id": "id",
        "tr": "tr", "pl": "pl"
    ]

    func code(for language: String) -> String? { AskTranslationLanguages.serviceCode(language, in: Self.codes) }

    /// What the signature covers: the text itself when short, otherwise its first
    /// ten characters, its length and its last ten.
    static func signedInput(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > 20 else { return text }
        var result = String.UnicodeScalarView(scalars.prefix(10))
        result.append(contentsOf: String(scalars.count).unicodeScalars)
        result.append(contentsOf: scalars.suffix(10))
        return String(result)
    }

    static func sign(appKey: String, text: String, salt: String, time: String, secret: String) -> String {
        AskTranslationSigning.sha256Hex(appKey + signedInput(text) + salt + time + secret)
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        let time = String(Int(context.now.timeIntervalSince1970))
        var request = URLRequest(url: URL(string: "https://openapi.youdao.com/api")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = AskTranslationSigning.formBody([
            ("q", text), ("from", source ?? "auto"), ("to", target), ("appKey", credentials.key),
            ("salt", context.salt), ("sign", Self.sign(appKey: credentials.key, text: text, salt: context.salt,
                                                       time: time, secret: credentials.secret)),
            ("signType", "v3"), ("curtime", time)
        ])
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        guard status == 200 else { throw AskTranslationServiceError.status(status) }
        guard let object = AskTranslationSigning.object(data) else { throw AskTranslationServiceError.invalidResponse }
        let code = (object["errorCode"] as? String) ?? (object["errorCode"] as? Int).map(String.init) ?? ""
        guard code == "0" else { throw Self.error(code) }
        guard let translation = object["translation"] as? [String], !translation.isEmpty else {
            throw AskTranslationServiceError.invalidResponse
        }
        return translation.joined(separator: "\n")
    }

    static func error(_ code: String) -> AskTranslationServiceError {
        switch code {
        case "102": .unsupportedLanguage
        case "103": .tooLong
        case "108", "110", "111", "202", "206": .authentication
        case "401": .quota
        case "411", "412": .rateLimited
        default: .service(code)
        }
    }
}
