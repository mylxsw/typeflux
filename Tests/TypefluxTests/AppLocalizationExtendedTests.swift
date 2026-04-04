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
