import Foundation
import NaturalLanguage

/// Languages the translation plugin offers, as BCP 47 codes ("en", "zh-Hans"),
/// and how it picks a direction: into the interface language, or out of it into
/// the second language.
enum AskTranslationLanguages {
    /// The languages ⇥ moves through after the interface and second language.
    static let common = ["en", "zh-Hans", "ja", "ko", "fr", "de", "es", "zh-Hant", "ru", "pt", "it"]

    static func code(for language: AppLanguage) -> String {
        switch language {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    /// The second language when the user has not chosen one: English, or
    /// Simplified Chinese for someone whose interface is in English.
    static func defaultSecond(for interface: AppLanguage) -> String {
        interface == .english ? "zh-Hans" : "en"
    }

    /// "English", "日语": the language's name in the interface language.
    static func name(_ code: String, in interface: AppLanguage) -> String {
        let locale = Locale(identifier: interface.localeIdentifier)
        return locale.localizedString(forIdentifier: code) ?? code
    }

    /// Into the interface language, or into the second language when the text
    /// is already in the interface language. A preset or chosen target wins.
    static func target(source: String?, primary: String, second: String, preset: String?) -> String {
        if let preset, !preset.isEmpty { return preset }
        guard let source else { return primary }
        return sameLanguage(source, primary) ? second : primary
    }

    /// Simplified and Traditional Chinese are different targets; "en-US" and "en" are the same.
    static func sameLanguage(_ first: String, _ second: String) -> Bool {
        func base(_ code: String) -> String {
            let lowered = code.lowercased()
            if lowered.hasPrefix("zh") { return lowered.contains("hant") || lowered.contains("tw") || lowered.contains("hk") ? "zh-hant" : "zh-hans" }
            return String(lowered.split(separator: "-").first ?? "")
        }
        return base(first) == base(second)
    }

    /// Every target ⇥ can reach, in order, without repeats.
    static func cycle(primary: String, second: String) -> [String] {
        var seen = Set<String>()
        return ([primary, second] + common).filter { code in
            !seen.contains(where: { sameLanguage($0, code) }) && seen.insert(code).inserted
        }
    }

    /// The target `step` places from `current` in the cycle (⇥ is +1, ⇧⇥ is −1).
    static func step(from current: String, by step: Int, primary: String, second: String, skipping source: String?) -> String {
        let options = cycle(primary: primary, second: second).filter { code in source.map { !sameLanguage($0, code) } ?? true }
        guard !options.isEmpty else { return current }
        let index = options.firstIndex { sameLanguage($0, current) } ?? -1
        let next = ((index + step) % options.count + options.count) % options.count
        return options[next]
    }
}

/// Which language a piece of text is in. A protocol, so tests choose the answer.
protocol AskLanguageDetecting: Sendable {
    /// A BCP 47 code, or nil when the text is too short or mixed to tell.
    func detect(_ text: String, hints: [String]) -> String?
}

struct AskLanguageDetector: AskLanguageDetecting {
    static let minimumConfidence = 0.6

    func detect(_ text: String, hints: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        // Short text is ambiguous; lean towards the languages this user works in.
        var weights: [NLLanguage: Double] = [:]
        // NaturalLanguage names languages like BCP 47, Chinese included ("zh-Hans").
        for hint in hints { weights[NLLanguage(rawValue: hint)] = 0.3 }
        recognizer.languageHints = weights
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= Self.minimumConfidence else {
            return nil
        }
        return best.key.rawValue
    }
}
