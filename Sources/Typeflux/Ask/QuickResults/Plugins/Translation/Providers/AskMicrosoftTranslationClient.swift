import Foundation

/// Azure AI Translator v3. Regional and multi-service resources also need their region.
struct AskMicrosoftTranslationClient: AskTranslationProviderClient {
    let provider = AskTranslationProvider.microsoft
    // A request takes up to 50,000 characters; smaller pieces fail less.
    let limit = 10000

    static let overrides = ["zh-hans": "zh-Hans", "zh-hant": "zh-Hant", "nb": "nb", "no": "nb"]

    func code(for language: String) -> String? {
        let base = AskTranslationLanguages.base(language)
        if let code = Self.overrides[base] { return code }
        return base.isEmpty ? nil : base
    }

    func request(_ text: String, source: String?, target: String, credentials: AskTranslationCredentials,
                 context: AskTranslationRequestContext) throws -> URLRequest {
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [URLQueryItem(name: "api-version", value: "3.0"), URLQueryItem(name: "to", value: target)]
            + (source.map { [URLQueryItem(name: "from", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(credentials.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let region = credentials.region(for: provider)
        if !region.isEmpty { request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try AskTranslationSigning.json([["Text": text]])
        return request
    }

    func translation(from data: Data, status: Int) throws -> String {
        guard status == 200 else {
            let error = AskTranslationSigning.object(data)?["error"] as? [String: Any]
            // Codes are the status followed by three digits: 401000, 403001, 400036.
            let code = (error?["code"] as? Int) ?? 0
            switch code {
            case 400_035, 400_036, 400_019, 400_023: throw AskTranslationServiceError.unsupportedLanguage
            case 400_050, 400_077: throw AskTranslationServiceError.tooLong
            case 403_001: throw AskTranslationServiceError.quota
            default: throw AskTranslationServiceError.status(status)
            }
        }
        let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        guard let translations = items?.first?["translations"] as? [[String: Any]],
              let text = translations.first?["text"] as? String else { throw AskTranslationServiceError.invalidResponse }
        return text
    }
}
