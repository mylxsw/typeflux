import Foundation

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("AppLocalization.appLanguageDidChange")
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"

    var id: String {
        rawValue
    }

    var localeIdentifier: String {
        rawValue
    }

    /// ISO 639-1 language code accepted by WhisperKit's DecodingOptions.
    var whisperKitLanguageCode: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese, .traditionalChinese: "zh"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    var bundleLocalizationName: String {
        rawValue
    }

    var bundleLocalizationCandidates: [String] {
        var candidates = [rawValue]
        let lowercased = rawValue.lowercased()
        if lowercased != rawValue {
            candidates.append(lowercased)
        }
        return candidates
    }

    var displayName: String {
        switch self {
        case .english:
            L("language.option.english")
        case .simplifiedChinese:
            L("language.option.simplifiedChinese")
        case .traditionalChinese:
            L("language.option.traditionalChinese")
        case .japanese:
            L("language.option.japanese")
        case .korean:
            L("language.option.korean")
        }
    }

    /// Stable English label for prompt construction.
    var promptDisplayName: String {
        switch self {
        case .english:
            "English"
        case .simplifiedChinese:
            "Simplified Chinese"
        case .traditionalChinese:
            "Traditional Chinese"
        case .japanese:
            "Japanese"
        case .korean:
            "Korean"
        }
    }

    static func defaultLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let language = preferredLanguages.first?.lowercased() else {
            return .english
        }

        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") {
            return .traditionalChinese
        }

        if language.hasPrefix("zh") {
            return .simplifiedChinese
        }

        if language.hasPrefix("ja") {
            return .japanese
        }

        if language.hasPrefix("ko") {
            return .korean
        }

        return .english
    }
}

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()

    @Published private(set) var language: AppLanguage
    private var stringTableCache: [String: [String: String]] = [:]

    private init(settingsStore: SettingsStore = SettingsStore()) {
        language = settingsStore.appLanguage
    }

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        NotificationCenter.default.post(name: .appLanguageDidChange, object: language)
    }

    func string(_ key: String, arguments: [CVarArg] = []) -> String {
        let localized = localizedString(for: key, language: language)

        guard !arguments.isEmpty else { return localized }
        return String(format: localized, locale: locale, arguments: arguments)
    }

    private func localizedString(for key: String, language: AppLanguage) -> String {
        for localizationName in language.bundleLocalizationCandidates {
            if let cached = stringTableCache[localizationName], let localized = cached[key] {
                return localized
            }

            guard
                let tableURL = Bundle.appResources.url(
                    forResource: "Localizable",
                    withExtension: "strings",
                    subdirectory: nil,
                    localization: localizationName,
                ),
                let dictionary = NSDictionary(contentsOf: tableURL) as? [String: String]
            else {
                continue
            }

            stringTableCache[localizationName] = dictionary
            if let localized = dictionary[key] {
                return localized
            }
        }

        return bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    private func bundle(for language: AppLanguage) -> Bundle {
        for localizationName in language.bundleLocalizationCandidates {
            if let path = Bundle.appResources.path(forResource: localizationName, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }

        return Bundle.appResources
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.shared.string(key, arguments: arguments)
}
