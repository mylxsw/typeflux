@testable import Typeflux
import XCTest

final class AppLocalizationTests: XCTestCase {
    func testDefaultLanguageMatchesJapaneseAndKoreanPreferredLanguages() {
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["ko-KR"]), .korean)
    }

    func testDefaultLanguageKeepsChineseVariantsAndFallsBackToEnglish() {
        XCTAssertEqual(
            AppLanguage.defaultLanguage(preferredLanguages: ["zh-Hant-TW"]),
            .traditionalChinese
        )
        XCTAssertEqual(
            AppLanguage.defaultLanguage(preferredLanguages: ["zh-CN"]),
            .simplifiedChinese
        )
        XCTAssertEqual(AppLanguage.defaultLanguage(preferredLanguages: ["fr-FR"]), .english)
    }
}
