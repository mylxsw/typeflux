import Foundation

/// DeepL API v2. Free keys end in ":fx" and use their own host.
struct AskDeepLTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.deepl
    // Requests may be 128 KiB; the text stays well below that.
    let limit = 30000
    let limitUnit = AskTranslationTextChunker.Unit.utf8Bytes

    static let targets = [
        "en": "EN-US", "zh-hans": "ZH-HANS", "zh-hant": "ZH-HANT", "ja": "JA", "ko": "KO", "fr": "FR", "de": "DE",
        "es": "ES", "ru": "RU", "pt": "PT-BR", "it": "IT", "nl": "NL", "pl": "PL", "sv": "SV", "da": "DA", "fi": "FI",
        "cs": "CS", "el": "EL", "hu": "HU", "id": "ID", "tr": "TR", "uk": "UK", "ar": "AR", "nb": "NB", "ro": "RO",
        "bg": "BG", "et": "ET", "lv": "LV", "lt": "LT", "sk": "SK", "sl": "SL"
    ]

    func code(for language: String) -> String? { AskTranslationLanguages.serviceCode(language, in: Self.targets) }

    static func host(for key: String) -> String {
        key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        var request = URLRequest(url: URL(string: Self.host(for: credentials.key) + "/v2/translate")!)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key " + credentials.key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [text], "target_lang": target]
        // Sources take the bare language: "ZH", not "ZH-HANS".
        if let source { body["source_lang"] = String(source.split(separator: "-")[0]) }
        request.httpBody = try AskTranslationSigning.json(body)
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        guard status == 200 else {
            if status == 400, let message = AskTranslationSigning.object(data)?["message"] as? String,
               message.lowercased().contains("lang") {
                throw AskTranslationServiceError.unsupportedLanguage
            }
            throw AskTranslationServiceError.status(status)
        }
        guard let translations = AskTranslationSigning.object(data)?["translations"] as? [[String: Any]],
              !translations.isEmpty else { throw AskTranslationServiceError.invalidResponse }
        return translations.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
