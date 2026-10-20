import Foundation
@testable import Typeflux
import XCTest

final class LocalizationResourceTests: XCTestCase {
    func testLauncherGeneralAndInputSourceCopyExistsInEveryLanguage() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL),
                                                                             options: [],
                                                                             format: nil) as? [String: String])
            for key in ["launcher.pane.basics", "launcher.inputSource.title", "launcher.inputSource.detail",
                        "launcher.inputSource.none", "launcher.inputSource.unavailable"] {
                XCTAssertFalse(try XCTUnwrap(table[key], "Missing \(key) in \(language.rawValue)").isEmpty)
            }
            if language == .simplifiedChinese {
                XCTAssertEqual(table["launcher.pane.basics"], "通用")
            } else if language == .english {
                XCTAssertEqual(table["launcher.pane.basics"], "General")
            }
        }
    }

    func testGeneralSettingsSectionTitlesExistAndQuickInputCopyIsGoneInEveryLanguage() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL),
                                                                             options: [],
                                                                             format: nil) as? [String: String])
            for key in ["settings.general.app.title", "settings.general.voiceInput.title",
                        "settings.general.memory.title", "settings.general.screenshot.title"] {
                XCTAssertFalse(try XCTUnwrap(table[key], "Missing \(key) in \(language.rawValue)").isEmpty)
            }
            XCTAssertNil(table["settings.general.voiceTrigger.title"])
            XCTAssertNil(table["settings.audio"])
            for key in ["settings.shortcuts.quickInput.title", "settings.shortcuts.quickInput.subtitle",
                        "overlay.recording.quickInputHint", "settings.inputAndCapture.title",
                        "settings.shortcuts.launcherPosition.reset"] {
                XCTAssertNil(table[key], "\(key) should be removed from \(language.rawValue)")
            }
            if language == .simplifiedChinese {
                XCTAssertEqual(table["settings.general.voiceInput.title"], "语音输入")
                XCTAssertEqual(table["settings.general.memory.title"], "记忆与词汇")
            }
        }
    }

    func testKeywordShortcutGuidanceExistsInEveryLanguage() throws {
        let keys = ["hotkeys.keyword.add", "hotkeys.keyword.sheet.addTitle",
                    "hotkeys.keyword.sheet.editTitle",
                    "hotkeys.keyword.sheet.record", "hotkeys.keyword.sheet.shortcutHint"]
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "Missing \(key) in \(language.rawValue)")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }

    func testLauncherPolishKeysAndChineseTerminologyAreComplete() throws {
        let keys = ["cloud.error.llmSignInRequired", "cloud.error.asrSignInRequired",
                    "ask.plugin.prompt.description.polish", "ask.plugin.prompt.description.summarize",
                    "ask.plugin.prompt.description.explain", "ask.plugin.translate.signInFallback"]
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL),
                options: [], format: nil) as? [String: String])
            for key in keys {
                XCTAssertFalse(try XCTUnwrap(table[key], "Missing \(key) in \(language.rawValue)").isEmpty)
            }
            XCTAssertEqual(try XCTUnwrap(table["ask.plugin.translate.signInFallback"]).components(separatedBy: "%@").count, 2)
            if [.simplifiedChinese, .traditionalChinese].contains(language) {
                XCTAssertFalse(table.values.contains { $0.contains("关键字") || $0.contains("關鍵字") })
            }
        }
    }

    func testSidebarCloudPromoKeysExistInEveryLanguage() throws {
        let keys = ["ask.cloudPromo.vision", "ask.cloudPromo.search", "ask.cloudPromo.sync",
                    "ask.cloudPromo.signIn", "ask.cloudPromo.dismiss", "ask.local.identity.localMode"]
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL),
                options: [], format: nil) as? [String: String])
            for key in keys {
                XCTAssertFalse(try XCTUnwrap(table[key], "Missing \(key) in \(language.rawValue)").isEmpty)
            }
            // The card lists features instead of the old explanatory sentence.
            XCTAssertNil(table["ask.cloudPromo.body"], "Stale ask.cloudPromo.body in \(language.rawValue)")
        }
    }

    func testMainAppDeclaresAllResourceLocalizations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("app/Info.plist")),
            options: [], format: nil) as? [String: Any])
        let languages = try XCTUnwrap(plist["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(languages), Set(["en", "zh-Hans", "zh-Hant", "ja", "ko"]))
    }

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

    func testVoiceInputSidebarTitleHasLocalizedValueForAllSupportedLanguages() throws {
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let localized = bundle.localizedString(forKey: "studio.section.voiceInput", value: nil, table: nil)

            XCTAssertNotEqual(localized, "studio.section.voiceInput", "Missing localized value for \(language.rawValue)")
        }
    }

    func testVoiceProcessingTimeoutCopyAndFormatArgumentsExistInEveryLanguage() throws {
        let plainKeys = [
            "settings.advanced.voiceProcessingTimeout.title",
            "settings.advanced.voiceProcessingTimeout.subtitle"
        ]
        let formattedKeys = [
            "settings.advanced.voiceProcessingTimeout.option",
            "history.race.priorityExceeded",
            "history.race.priorityExceededCancelled",
            "history.race.reason.cloudWithinWindow",
            "history.race.reason.cloudAfterWindow",
            "history.race.reason.localAtDeadline",
            "history.race.reason.localAfterWindow",
            "overlay.timeout.message",
            "workflow.timeout.reason"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in plainKeys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertFalse(localized.isEmpty)
            }
            for key in formattedKeys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertEqual(localized.components(separatedBy: "%d").count - 1, 1, key)
            }
        }
    }

    func testInstantVoiceInputExplainsBenefitAndMicrophoneTradeoffInEveryLanguage() throws {
        let keys = [
            "settings.instantVoiceInput.title",
            "settings.instantVoiceInput.subtitle",
            "settings.instantVoiceInput.suggestion.title",
            "settings.instantVoiceInput.suggestion.message",
            "settings.instantVoiceInput.suggestion.enable"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertFalse(localized.isEmpty)
            }

            let subtitle = bundle.localizedString(forKey: "settings.instantVoiceInput.subtitle", value: nil, table: nil)
            XCTAssertTrue(subtitle.contains("15"), language.rawValue)
            for overpromise in ["without missing anything", "不漏任何", "不漏掉任何", "漏らさず", "빠짐없이"] {
                XCTAssertFalse(subtitle.contains(overpromise), "Overpromise in \(language.rawValue)")
            }
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
            "custom", "clearSearch", "summary.typeflux",
            "summary.translator", "customPersona"
        ].map { "settings.personas." + $0 } + [
            "library", "builtIn", "none", "noResults", "discardChanges", "save", "create",
            "copyToEdit", "guardTitle", "deleteDefault", "deleteAuxiliary", "undo"
        ].map { "personas.redesign." + $0 }
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

    func testModelSettingsCopyExistsInEveryLanguage() throws {
        let plainKeys = [
            "models.connection",
            "models.useForRewrite",
            "models.visionUnknownShort",
            "models.capabilityHint",
            "models.visionYes",
            "models.reasoningYes",
            "models.visionGuessed",
            "ask.models.visionTrial",
            "ask.image.untested",
            "models.showKey",
            "models.hideKey",
            "models.cloud.managedShort",
            "models.usageHint",
            "models.tab.scenes",
            "models.tab.speech",
            "models.tab.language"
        ]

        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            for key in plainKeys {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(localized, key, "Missing localized value for \(key) in \(language.rawValue)")
                XCTAssertFalse(localized.isEmpty)
            }
            // Vision means reading any image, not just screenshots; the copy must say so.
            for key in ["models.visionYes", "models.noVision", "models.unknownVision", "models.visionUnknownShort"] {
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil).lowercased()
                for word in ["screenshot", "截图", "截圖", "スクリーンショット", "스크린샷"] {
                    XCTAssertFalse(localized.contains(word), "\(key) mentions screenshots in \(language.rawValue)")
                }
            }
            for key in ["models.rewriteBlocked", "models.askBlocked"] {
                let format = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(format, key, "Missing \(key) in \(language.rawValue)")
                XCTAssertEqual(format.components(separatedBy: "%@").count - 1, 1, "\(key) in \(language.rawValue)")
            }
            let searchEmpty = bundle.localizedString(forKey: "models.searchEmpty", value: nil, table: nil)
            XCTAssertNotEqual(searchEmpty, "models.searchEmpty", "Missing models.searchEmpty in \(language.rawValue)")
            XCTAssertEqual(searchEmpty.components(separatedBy: "%@").count - 1, 1, language.rawValue)
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

extension LocalizationResourceTests {
    func testLauncherSettingsTitleNamesTypefluxInEveryLanguage() throws {
        let expected: [AppLanguage: String] = [
            .english: "Typeflux Settings", .simplifiedChinese: "Typeflux 设置",
            .traditionalChinese: "Typeflux 設定", .japanese: "Typeflux 設定", .korean: "Typeflux 설정"
        ]
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL),
                options: [], format: nil) as? [String: String])
            XCTAssertEqual(table["ask.plugin.setting.title"], try XCTUnwrap(expected[language]), language.rawValue)
        }
    }
}

extension LocalizationResourceTests {
    func testEveryClientLanguageContainsTheSameKeysAsEnglish() throws {
        func table(for language: AppLanguage) throws -> [String: String] {
            let bundle = try localizationBundle(for: language)
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                options: [], format: nil) as? [String: String])
        }

        let englishKeys = Set(try table(for: .english).keys)
        for language in AppLanguage.allCases {
            let localized = try table(for: language)
            XCTAssertEqual(Set(localized.keys), englishKeys, "Incomplete strings for \(language.rawValue)")
        }
    }

    func testScreenshotEditorCopyExistsInEveryLanguage() throws {
        var keys = ScreenshotAnnotationTool.allCases.map { "screenshot.tool.\($0.rawValue)" }
        keys += ["undo", "redo", "cancel", "save", "copy", "color", "size", "fontSize", "counterSize", "opacity",
                 "cornerRadius"].map { "screenshot.edit.\($0)" }
        keys += ScreenshotAnnotationStyle.Color.presets.compactMap(\.presetName).map { "screenshot.color.\($0)" }
        keys += ["recent", "pick"].map { "screenshot.color.\($0)" }
        keys += ScreenshotAnnotationStyle.Fill.allCases.map { "screenshot.fill.\($0.rawValue)" }
        keys += ScreenshotAnnotationStyle.Dash.allCases.map { "screenshot.dash.\($0.rawValue)" }
        keys += ScreenshotAnnotationEditor.MosaicShape.allCases.map { "screenshot.mosaic.shape.\($0.rawValue)" }
        keys += ScreenshotMosaic.Effect.allCases.map { "screenshot.mosaic.effect.\($0.rawValue)" }
        keys += ["", ".low", ".medium", ".high"].map { "screenshot.mosaic.strength\($0)" }
        keys += ["title", "enabled", "preview", "failed", "background", "padding", "radius", "shadow",
                 "reset", "cancel", "apply"].map { "screenshot.beautify.\($0)" }
        keys += ScreenshotBeautification.Background.allCases.map { "screenshot.beautify.background.\($0.rawValue)" }
        for language in AppLanguage.allCases {
            let bundle = try localizationBundle(for: language)
            let tableURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: tableURL),
                options: [], format: nil) as? [String: String])
            for key in keys {
                XCTAssertFalse(try XCTUnwrap(table[key], "Missing \(key) in \(language.rawValue)").isEmpty)
            }
            XCTAssertNil(table["screenshot.overlay.hint"], "The toolbar replaced the hint")
            XCTAssertNil(table["screenshot.width.thin"], "Sizes are a slider now")
        }
    }
}
