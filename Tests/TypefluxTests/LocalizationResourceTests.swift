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

    func testInstantVoiceInputExplainsBenefitAndMicrophoneTradeoffInEveryLanguage() throws {
        let keys = [
            "settings.instantVoiceInput.title",
            "settings.instantVoiceInput.subtitle"
        ]
        let expectedSubtitles: [AppLanguage: String] = [
            .english: "Shortens microphone startup time, so you can speak as soon as you press the shortcut without missing anything. The microphone stays on for 15 minutes after use.",
            .simplifiedChinese: "缩短麦克风启动耗时，按下快捷键就能直接说话，不漏任何内容。使用后麦克风会保持启用 15 分钟。",
            .traditionalChinese: "縮短麥克風啟動時間，按下快速鍵就能直接說話，不漏掉任何內容。使用後麥克風會保持啟用 15 分鐘。",
            .japanese: "マイクの起動時間を短縮し、ショートカットを押したらすぐに話せます。話した内容を最初から漏らさず記録します。使用後はマイクが15分間オンになります。",
            .korean: "마이크 시작 시간을 줄여 단축키를 누르자마자 말해도 모든 내용을 빠짐없이 녹음합니다. 사용 후 마이크는 15분 동안 켜진 상태를 유지합니다."
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertFalse(localized.isEmpty)
            }

            let subtitle = bundle.localizedString(
                forKey: "settings.instantVoiceInput.subtitle",
                value: nil,
                table: nil
            )
            XCTAssertEqual(subtitle, try XCTUnwrap(expectedSubtitles[language]))
        }

        let chineseBundle = try localizationBundle(for: .simplifiedChinese)
        let chineseTitle = chineseBundle.localizedString(
            forKey: "settings.instantVoiceInput.title",
            value: nil,
            table: nil
        )
        XCTAssertEqual(chineseTitle, "按键即说")
    }

    func testSidebarAccountCardStateCopyExistsForAllSupportedLanguages() throws {
        let keys = [
            "sidebar.accountCard.guest",
            "sidebar.accountCard.cloudCredits",
            "auth.account.usageQuotaUnlimited",
            "auth.account.logout",
            "sidebar.accountCard.usagePair",
            "sidebar.accountCard.viewAccountAccessibility",
            "sidebar.accountCard.billingAttention",
            "sidebar.accountCard.billingAttentionSubtitle",
            "sidebar.accountCard.unavailable"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertFalse(localized.isEmpty)
            }
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

    func testPersonaLibraryCopyExistsForAllSupportedLanguages() throws {
        let keys = [
            "settingsTitle", "none", "builtIn", "custom", "clearSearch", "noResults",
            "default", "readOnly", "unsaved", "saveChanges", "summary.typeflux",
            "summary.translator", "customPersona"
        ].map { "settings.personas." + $0 }
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "Missing \(key) in \(language.rawValue)")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }

    func testPersonaDefinitionUsesUserFriendlyCopyForAllSupportedLanguages() throws {
        let expectedValues: [AppLanguage: String] = [
            .english: "Persona Definition",
            .simplifiedChinese: "人设定义",
            .traditionalChinese: "人設定義",
            .japanese: "ペルソナ定義",
            .korean: "페르소나 정의"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(forKey: "settings.personas.prompt", value: nil, table: nil)

            XCTAssertEqual(
                localized,
                expectedValues[language],
                "Unexpected persona definition copy in \(language.rawValue)"
            )
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

    func testHistoryRaceAndLLMOutcomeCopyExistsForAllSupportedLanguages() throws {
        let keys = [
            "history.race.selected",
            "history.race.cloud",
            "history.race.local",
            "history.race.priorityExceededCancelled",
            "history.race.reason.localAtDeadline",
            "history.llmOutcome.completed",
            "history.llmOutcome.timedOutFallback",
            "history.llmOutcome.requestFailedFallback",
            "history.llmOutcome.failed"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertFalse(localized.isEmpty)
            }
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

    func testAccountOverviewCopyAndFormatArgumentsExistInEveryLanguage() throws {
        let keysAndArgumentCounts = [
            "auth.account.logoutConfirmTitle": 0,
            "auth.account.logoutConfirmMessage": 0,
            "auth.account.nextRenewal": 1,
            "auth.account.refreshOverview": 0,
            "auth.account.signedInWith": 1,
            "auth.account.usageQuotaCurrentPeriod": 0,
            "auth.account.usageFreeQuota": 0,
            "sidebar.accountCard.remaining": 1,
            "auth.account.usageQuotaRemainingPercentage": 1,
            "auth.account.usageQuotaRemainingPair": 2,
            "auth.account.usageQuotaExplanationTitle": 0,
            "auth.account.usageQuotaExplanation": 0,
            "cloudDataSync.accountDescription": 0,
            "cloudDataSync.manageData": 0,
            "cloudDataSync.status.lastSyncAgo": 1
        ]
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for (key, argumentCount) in keysAndArgumentCounts {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing \(key) in \(language.rawValue)")
                XCTAssertEqual(localized.components(separatedBy: "%@").count - 1, argumentCount, key)
            }

            let quotaPair = bundle.localizedString(forKey: "auth.account.usageQuotaRemainingPair", value: nil, table: nil)
            XCTAssertEqual(
                String(format: quotaPair, "1,234", "90,000"),
                "1,234 / 90,000",
                "The quota header should show only the numeric pair in \(language.rawValue)"
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
