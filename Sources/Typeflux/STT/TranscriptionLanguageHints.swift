import Foundation
import Speech

enum TranscriptionLanguageHints {
    static func speechRecognizerLocale() -> Locale? {
        for identifier in preferredLocaleCandidates() {
            let locale = Locale(identifier: identifier)
            if SFSpeechRecognizer(locale: locale) != nil {
                return locale
            }
        }
        return nil
    }

    static func remotePrompt(vocabularyTerms: [String]) -> String? {
        let sections = [
            languageBiasPrompt(),
            PromptCatalog.transcriptionVocabularyHint(terms: vocabularyTerms),
        ]
        .compactMap { section in
            let trimmed = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private static func languageBiasPrompt() -> String? {
        guard let language = Locale.preferredLanguages.first?.lowercased() else { return nil }

        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") {
            return "The speaker is most likely using Traditional Chinese. Prefer Chinese transcription over English phonetic guesses unless the audio is clearly another language."
        }

        if language.hasPrefix("zh") {
            return "The speaker is most likely using Simplified Chinese. Prefer Chinese transcription over English phonetic guesses unless the audio is clearly another language."
        }

        return nil
    }

    private static func preferredLocaleCandidates() -> [String] {
        var candidates: [String] = []
        for language in Locale.preferredLanguages {
            candidates.append(contentsOf: mappedLocaleCandidates(from: language))
        }

        candidates.append(contentsOf: mappedLocaleCandidates(from: Locale.current.identifier))
        candidates.append(contentsOf: ["zh-CN", "en-US"])

        var seen = Set<String>()
        return candidates.filter { identifier in
            guard !identifier.isEmpty, !seen.contains(identifier) else { return false }
            seen.insert(identifier)
            return true
        }
    }

    static func mappedLocaleCandidates(from identifier: String) -> [String] {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let lowercased = normalized.lowercased()

        if lowercased.hasPrefix("zh-hant") || lowercased.hasPrefix("zh-tw") {
            return ["zh-TW", "zh-HK", "zh-Hant"]
        }

        if lowercased.hasPrefix("zh-hk") {
            return ["zh-HK", "zh-TW", "zh-Hant"]
        }

        if lowercased.hasPrefix("zh") {
            return ["zh-CN", "zh-Hans"]
        }

        let components = normalized.split(separator: "-").map(String.init)
        guard let languageCode = components.first else { return [] }

        if components.count >= 2 {
            return [normalized, languageCode]
        }

        return [languageCode]
    }
}
