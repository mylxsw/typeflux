import Foundation

/// Google Cloud Translation Basic (v2) with an API key.
struct AskGoogleTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.google
    // Google recommends at most 5,000 characters a request.
    let limit = 5000

    static let overrides = ["zh-hans": "zh-CN", "zh-hant": "zh-TW", "he": "iw"]

    func code(for language: String) -> String? {
        let base = AskTranslationLanguages.base(language)
        if let code = Self.overrides[base] { return code }
        return base.isEmpty ? nil : base
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://translation.googleapis.com/language/translate/v2")!)
        request.httpMethod = "POST"
        // In a header, so the key stays out of URLs and their logs.
        request.setValue(credentials.key, forHTTPHeaderField: "X-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["q": [text], "target": target, "format": "text"]
        if let source { body["source"] = source }
        request.httpBody = try AskTranslationSigning.json(body)
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        let object = AskTranslationSigning.object(data)
        guard status == 200 else {
            let error = object?["error"] as? [String: Any]
            let message = (error?["message"] as? String ?? "").lowercased()
            if status == 400, message.contains("api key") { throw AskTranslationServiceError.authentication }
            if status == 400, message.contains("language") { throw AskTranslationServiceError.unsupportedLanguage }
            if status == 403, message.contains("quota") || message.contains("limit") {
                throw AskTranslationServiceError.quota
            }
            throw AskTranslationServiceError.status(status)
        }
        guard let translations = (object?["data"] as? [String: Any])?["translations"] as? [[String: Any]],
              !translations.isEmpty else { throw AskTranslationServiceError.invalidResponse }
        return translations.compactMap { $0["translatedText"] as? String }.joined(separator: "\n")
    }
}
