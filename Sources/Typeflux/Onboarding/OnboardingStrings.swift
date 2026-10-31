import Foundation

/// Page-local tables avoid concurrent edits to Localizable.strings during stage two.
enum OnboardingStrings {
    static func text(_ key: String, table: String = "OnboardingShared",
                     language: AppLanguage = AppLocalization.shared.language,
                     arguments: [CVarArg] = []) -> String {
        let value = lookup(key, table: table, language: language)
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language.rawValue),
                                                  arguments: arguments)
    }

    private static func lookup(_ key: String, table: String, language: AppLanguage) -> String {
        for candidate in language.bundleLocalizationCandidates + ["en"] {
            guard let path = Bundle.appResources.path(forResource: candidate, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            let value = bundle.localizedString(forKey: key, value: key, table: table)
            if value != key {
                return value
            }
        }
        return key
    }
}
