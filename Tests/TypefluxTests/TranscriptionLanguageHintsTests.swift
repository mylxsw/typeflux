@testable import Typeflux
import XCTest

final class TranscriptionLanguageHintsTests: XCTestCase {
    // MARK: - mappedLocaleCandidates

    func testChineseTraditionalTW() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-Hant-TW")
        XCTAssertEqual(candidates, ["zh-TW", "zh-HK", "zh-Hant"])
    }

    func testChineseTraditionalHK() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-HK")
        XCTAssertEqual(candidates, ["zh-HK", "zh-TW", "zh-Hant"])
    }

    func testChineseSimplified() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-Hans-CN")
        XCTAssertEqual(candidates, ["zh-CN", "zh-Hans"])
    }

    func testChineseSimplifiedPlain() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh")
        XCTAssertEqual(candidates, ["zh-CN", "zh-Hans"])
    }

    func testEnglishUS() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "en-US")
        XCTAssertEqual(candidates, ["en-US", "en"])
    }

    func testJapanese() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "ja")
        XCTAssertEqual(candidates, ["ja"])
    }

    func testJapaneseWithRegion() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "ja-JP")
        XCTAssertEqual(candidates, ["ja-JP", "ja"])
    }

    func testUnderscoreNormalization() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh_Hant_TW")
        XCTAssertEqual(candidates, ["zh-TW", "zh-HK", "zh-Hant"])
    }

    func testEmptyIdentifier() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "")
        XCTAssertEqual(candidates, [])
    }

    func testChineseTW() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-TW")
        XCTAssertEqual(candidates, ["zh-TW", "zh-HK", "zh-Hant"])
    }

    // MARK: - remotePrompt

    func testRemotePromptWithVocabularyTerms() {
        let prompt = TranscriptionLanguageHints.remotePrompt(vocabularyTerms: ["Typeflux", "SwiftUI"])
        if let prompt {
            XCTAssertTrue(prompt.contains("Typeflux") || prompt.contains("vocabulary"))
        }
    }

    func testRemotePromptEmptyVocabularyAndNoLanguageBias() {
        let prompt = TranscriptionLanguageHints.remotePrompt(vocabularyTerms: [])
        // May be nil if no language bias applies (non-Chinese locale)
        // Just verify it doesn't crash
        if let prompt {
            XCTAssertFalse(prompt.isEmpty)
        }
    }
}

// MARK: - Extended TranscriptionLanguageHints tests

extension TranscriptionLanguageHintsTests {
    // MARK: - mappedLocaleCandidates edge cases

    func testMappedLocaleForSimplifiedChinese() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh")
        XCTAssertEqual(candidates, ["zh-CN", "zh-Hans"])
    }

    func testMappedLocaleForZhHans() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-Hans")
        XCTAssertEqual(candidates, ["zh-CN", "zh-Hans"])
    }

    func testMappedLocaleForZhCN() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-CN")
        XCTAssertEqual(candidates, ["zh-CN", "zh-Hans"])
    }

    func testMappedLocaleForZhHK() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-HK")
        XCTAssertEqual(candidates, ["zh-HK", "zh-TW", "zh-Hant"])
    }

    func testMappedLocaleForKorean() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "ko")
        XCTAssertEqual(candidates, ["ko"])
    }

    func testMappedLocaleForKoreanWithRegion() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "ko-KR")
        XCTAssertEqual(candidates, ["ko-KR", "ko"])
    }

    func testMappedLocaleForFrench() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "fr")
        XCTAssertEqual(candidates, ["fr"])
    }

    func testMappedLocaleForFrenchWithRegion() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "fr-FR")
        XCTAssertEqual(candidates, ["fr-FR", "fr"])
    }

    func testMappedLocalePreservesNormalizationFromUnderscore() {
        // "zh_CN" should be treated same as "zh-CN"
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh_CN")
        XCTAssertEqual(candidates, ["zh-CN", "zh-Hans"])
    }

    func testMappedLocaleForZhHantWithRegion() {
        let candidates = TranscriptionLanguageHints.mappedLocaleCandidates(from: "zh-Hant-TW")
        // Normalized: starts with "zh-hant" -> ["zh-TW", "zh-HK", "zh-Hant"]
        XCTAssertEqual(candidates, ["zh-TW", "zh-HK", "zh-Hant"])
    }
}
