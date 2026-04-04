import XCTest
@testable import Typeflux

final class AppLocalizationExtendedTests: XCTestCase {

    // MARK: - defaultLanguage

    func testDefaultLanguageReturnsSimplifiedChineseForZhHans() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-Hans"]), .simplifiedChinese)
    }

    func testDefaultLanguageReturnsTraditionalChineseForZhHant() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-Hant"]), .traditionalChinese)
    }

    func testDefaultLanguageReturnsTraditionalChineseForZhTW() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-TW"]), .traditionalChinese)
    }

    func testDefaultLanguageReturnsTraditionalChineseForZhHK() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-HK"]), .traditionalChinese)
    }

    func testDefaultLanguageReturnsJapaneseForJa() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ja"]), .japanese)
    }

    func testDefaultLanguageReturnsKoreanForKo() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ko"]), .korean)
    }

    func testDefaultLanguageReturnsEnglishForEn() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["en"]), .english)
    }

    func testDefaultLanguageReturnsEnglishForUnknownLanguage() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["de-DE"]), .english)
    }

    func testDefaultLanguageReturnsEnglishForEmptyPreferredLanguages() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: []), .english)
    }

    // MARK: - whisperKitLanguageCode

    func testWhisperKitLanguageCodeReturnsCorrectCodeForEachLanguage() {
        XCTAssertEqual(AppLanguage.english.whisperKitLanguageCode, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.whisperKitLanguageCode, "zh")
        XCTAssertEqual(AppLanguage.traditionalChinese.whisperKitLanguageCode, "zh")
        XCTAssertEqual(AppLanguage.japanese.whisperKitLanguageCode, "ja")
        XCTAssertEqual(AppLanguage.korean.whisperKitLanguageCode, "ko")
    }

    // MARK: - localeIdentifier

    func testLocaleIdentifierReturnsRawValue() {
        XCTAssertEqual(AppLanguage.english.localeIdentifier, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localeIdentifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.traditionalChinese.localeIdentifier, "zh-Hant")
        XCTAssertEqual(AppLanguage.japanese.localeIdentifier, "ja")
        XCTAssertEqual(AppLanguage.korean.localeIdentifier, "ko")
    }

    // MARK: - bundleLocalizationName

    func testBundleLocalizationNameReturnsLowercasedRawValue() {
        XCTAssertEqual(AppLanguage.english.bundleLocalizationName, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.bundleLocalizationName, "zh-hans")
        XCTAssertEqual(AppLanguage.traditionalChinese.bundleLocalizationName, "zh-hant")
        XCTAssertEqual(AppLanguage.japanese.bundleLocalizationName, "ja")
        XCTAssertEqual(AppLanguage.korean.bundleLocalizationName, "ko")
    }

    // MARK: - allCases

    func testAllCasesContainsAllLanguages() {
        let allCases = AppLanguage.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.english))
        XCTAssertTrue(allCases.contains(.simplifiedChinese))
        XCTAssertTrue(allCases.contains(.traditionalChinese))
        XCTAssertTrue(allCases.contains(.japanese))
        XCTAssertTrue(allCases.contains(.korean))
    }
}

// MARK: - AppLocalization singleton tests

final class AppLocalizationInstanceTests: XCTestCase {

    // MARK: - locale

    func testLocaleReturnsLocaleMatchingCurrentLanguage() {
        let localization = AppLocalization.shared
        let locale = localization.locale
        // The locale identifier should match the language's localeIdentifier
        XCTAssertEqual(locale.identifier, localization.language.localeIdentifier)
    }

    // MARK: - string()

    func testStringReturnsKeyWhenTranslationMissing() {
        // When a key doesn't exist in any bundle, the key itself is returned
        let localization = AppLocalization.shared
        let result = localization.string("__nonexistent_key_xyz__")
        XCTAssertEqual(result, "__nonexistent_key_xyz__")
    }

    func testStringReturnsKeyForEmptyKey() {
        let localization = AppLocalization.shared
        let result = localization.string("")
        XCTAssertEqual(result, "")
    }

    // MARK: - setLanguage notification

    func testSetLanguagePostsNotificationOnChange() {
        let localization = AppLocalization.shared
        let original = localization.language

        // Choose a different language to change to
        let newLanguage: AppLanguage = original == .english ? .japanese : .english

        let expectation = XCTestExpectation(description: "appLanguageDidChange posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { notification in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        localization.setLanguage(newLanguage)
        wait(for: [expectation], timeout: 1.0)

        // Restore original
        localization.setLanguage(original)
    }

    func testSetLanguageSameValueDoesNotPostNotification() {
        let localization = AppLocalization.shared
        let current = localization.language

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        localization.setLanguage(current)
        // Give a brief moment (the notification would post synchronously)
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(notificationCount, 0)
    }

    func testSetLanguageChangesLanguageProperty() {
        let localization = AppLocalization.shared
        let original = localization.language
        let newLanguage: AppLanguage = original == .english ? .japanese : .english

        localization.setLanguage(newLanguage)
        XCTAssertEqual(localization.language, newLanguage)

        // Restore
        localization.setLanguage(original)
    }

    // MARK: - L() global function

    func testLFunctionReturnsSameResultAsString() {
        let key = "__test_l_function_key__"
        let fromL = L(key)
        let fromString = AppLocalization.shared.string(key)
        XCTAssertEqual(fromL, fromString)
    }

    func testLFunctionWithNonExistentKeyReturnsKey() {
        let result = L("nonexistent.key.for.testing")
        XCTAssertEqual(result, "nonexistent.key.for.testing")
    }

    // MARK: - AppLanguage id

    func testAppLanguageIDMatchesRawValue() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(language.id, language.rawValue)
        }
    }

    // MARK: - AppLanguage defaultLanguage edge cases

    func testDefaultLanguageHandlesJapanesePrefixCorrectly() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ja-JP"]), .japanese)
    }

    func testDefaultLanguageHandlesKoreanPrefixCorrectly() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ko-KR"]), .korean)
    }

    func testDefaultLanguageHandlesZhWithRegion() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
    }

    func testDefaultLanguageHandlesZhHantWithRegion() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-Hant-TW"]), .traditionalChinese)
    }

    func testDefaultLanguageHandlesZhHantHK() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["zh-HK"]), .traditionalChinese)
    }

    func testDefaultLanguageHandlesUpperCaseZH() {
        // defaultLanguage lowercases internally before comparison
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ZH-Hans"]), .simplifiedChinese)
    }
}
