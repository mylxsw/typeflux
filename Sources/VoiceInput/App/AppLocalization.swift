import Foundation

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("AppLocalization.appLanguageDidChange")
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    var bundleLocalizationName: String {
        rawValue.lowercased()
    }

    var displayName: String {
        switch self {
        case .english:
            return L("language.option.english")
        case .simplifiedChinese:
            return L("language.option.simplifiedChinese")
        case .traditionalChinese:
            return L("language.option.traditionalChinese")
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

        return .english
    }
}

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()

    @Published private(set) var language: AppLanguage

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
        let localized = NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle(for: language),
            value: key,
            comment: ""
        )

        guard !arguments.isEmpty else { return localized }
        return String(format: localized, locale: locale, arguments: arguments)
    }

    private func bundle(for language: AppLanguage) -> Bundle {
        guard
            let path = Bundle.module.path(forResource: language.bundleLocalizationName, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return Bundle.module
        }

        return bundle
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.shared.string(key, arguments: arguments)
}
