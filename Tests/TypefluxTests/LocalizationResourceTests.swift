import Foundation
@testable import Typeflux
import XCTest

final class LocalizationResourceTests: XCTestCase {
    func testLocalizedStringTablesParseForAllSupportedLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let data = try Data(contentsOf: tableURL)

            XCTAssertNoThrow(
                try PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                "Failed to parse Localizable.strings for \(language.rawValue)",
            )
        }
    }

    func testSettingsGeneralHasLocalizedValueForAllSupportedLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(forKey: "settings.general", value: nil, table: nil)

            XCTAssertNotEqual(
                localized,
                "settings.general",
                "Missing localized value for \(language.rawValue)",
            )
        }
    }

    func testChineseOllamaProviderNameUsesRequestedWordOrder() throws {
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese] {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(forKey: "provider.llm.ollama", value: nil, table: nil)

            XCTAssertEqual(localized, "Ollama 本地")
        }
    }

    func testOverlayProcessingPhaseKeysExistForAllSupportedLanguages() throws {
        let keys = [
            "overlay.processing.transcribing",
            "overlay.processing.thinking",
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)

            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
            }
        }
    }

    private func localizationBundle(for language: AppLanguage) throws -> Bundle {
        let path = try XCTUnwrap(
            language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first,
            "Missing bundle path for \(language.rawValue)",
        )

        return try XCTUnwrap(Bundle(path: path), "Missing bundle for \(language.rawValue)")
    }
}
