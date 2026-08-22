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
                "Failed to parse Localizable.strings for \(language.rawValue)"
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
                "Missing localized value for \(language.rawValue)"
            )
        }
    }

    func testBillingPageUnavailableHasLocalizedValueForAllSupportedLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let key = "cloud.error.billingPageUnavailable"
            let localized = bundle.localizedString(forKey: key, value: nil, table: nil)

            XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
            XCTAssertFalse(localized.isEmpty)
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
            "overlay.processing.thinking"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)

            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
            }
        }
    }

    func testProcessingOverlayUsesThinkingCopyForAllSupportedLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let transcribing = bundle.localizedString(
                forKey: "overlay.processing.transcribing",
                value: nil,
                table: nil
            )
            let thinking = bundle.localizedString(forKey: "overlay.processing.thinking", value: nil, table: nil)

            XCTAssertEqual(
                transcribing,
                thinking,
                "Processing overlay should use thinking copy in \(language.rawValue)"
            )
        }
    }

    func testMenuProcessingStatusUsesThinkingCopyForAllSupportedLanguages() throws {
        let expectedValues: [AppLanguage: String] = [
            .english: "Thinking…",
            .simplifiedChinese: "思考中…",
            .traditionalChinese: "思考中…",
            .japanese: "思考中…",
            .korean: "생각 중…"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(forKey: "menu.status.processing", value: nil, table: nil)

            XCTAssertEqual(
                localized,
                expectedValues[language],
                "Unexpected processing status copy in \(language.rawValue)"
            )
        }
    }

    func testHistoryActionMenuDiscoverabilityCopyExistsForAllSupportedLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(forKey: "history.action.more", value: nil, table: nil)

            XCTAssertNotEqual(
                localized,
                "history.action.more",
                "Missing localized history actions menu label for \(language.rawValue)"
            )
            XCTAssertFalse(localized.isEmpty)
        }
    }

    func testAgentClarificationTranscribingHintUsesThinkingCopyForAllSupportedLanguages() throws {
        let expectedValues: [AppLanguage: String] = [
            .english: "Thinking...",
            .simplifiedChinese: "思考中...",
            .traditionalChinese: "思考中...",
            .japanese: "思考中...",
            .korean: "생각 중..."
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(
                forKey: "agent.clarification.transcribingHint",
                value: nil,
                table: nil
            )

            XCTAssertEqual(
                localized,
                expectedValues[language],
                "Unexpected clarification hint in \(language.rawValue)"
            )
        }
    }

    private func localizationBundle(for language: AppLanguage) throws -> Bundle {
        let path = try XCTUnwrap(
            language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first,
            "Missing bundle path for \(language.rawValue)"
        )

        return try XCTUnwrap(Bundle(path: path), "Missing bundle for \(language.rawValue)")
    }
}
