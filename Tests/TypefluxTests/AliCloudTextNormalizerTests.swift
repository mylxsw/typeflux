import XCTest
@testable import Typeflux

final class AliCloudTextNormalizerTests: XCTestCase {

    // MARK: - Empty and trivial cases

    func testNormalizeEmptySegmentReturnsEmpty() {
        let result = AliCloudTextNormalizer.normalize(segment: "", after: "existing text")
        XCTAssertEqual(result, "")
    }

    func testNormalizeIntoEmptyExistingTextReturnsSegmentDirectly() {
        let result = AliCloudTextNormalizer.normalize(segment: "hello", after: "")
        XCTAssertEqual(result, "hello")
    }

    // MARK: - Latin word spacing

    func testNormalizeLatin_afterLatin_addsSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "world", after: "hello")
        XCTAssertEqual(result, " world")
    }

    func testNormalizeLatinWord_afterWhitespace_noExtraSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "world", after: "hello ")
        XCTAssertEqual(result, "world")
    }

    func testNormalizeSegmentStartingWithWhitespace_noExtraSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: " world", after: "hello")
        XCTAssertEqual(result, " world")
    }

    // MARK: - CJK characters (no space)

    func testNormalizeChinese_afterChinese_noSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "世界", after: "你好")
        XCTAssertEqual(result, "世界")
    }

    func testNormalizeLatin_afterChinese_noSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "AI", after: "豆包")
        XCTAssertEqual(result, "AI")
    }

    func testNormalizeChinese_afterLatin_noSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "豆包", after: "AI")
        XCTAssertEqual(result, "豆包")
    }

    func testNormalizeJapanese_afterJapanese_noSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "世界", after: "日本語")
        XCTAssertEqual(result, "世界")
    }

    // MARK: - Punctuation boundaries

    func testNormalizeLatin_afterOpeningPunctuation_noSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: "hello", after: "(")
        XCTAssertEqual(result, "hello")
    }

    func testNormalizeClosingPunctuation_afterLatin_noSpace() {
        // The closing punctuation is the first char of the new segment
        let result = AliCloudTextNormalizer.normalize(segment: ".", after: "hello")
        XCTAssertEqual(result, ".")
    }

    func testNormalizeClosingComma_afterLatin_noSpace() {
        let result = AliCloudTextNormalizer.normalize(segment: ",", after: "word")
        XCTAssertEqual(result, ",")
    }

    func testNormalizeWord_afterClosingBracket_addsSpace() {
        // ']' is a closing punctuation on existing text side — but the rule only checks
        // if the new segment's first char is closing punctuation. Bracket is closing for segment first char.
        let result = AliCloudTextNormalizer.normalize(segment: "]", after: "data")
        XCTAssertEqual(result, "]")
    }

    func testNormalizeLatin_afterClosingParen_addsSpace() {
        // ')' is a closing punctuation but it's the last char of existing text, not first of segment
        // The rule: "if firstChar.isClosingPunctuation" — ')' is the existing text's last char,
        // new segment starts with latin so this should add a space
        let result = AliCloudTextNormalizer.normalize(segment: "world", after: ")")
        XCTAssertEqual(result, " world")
    }

    // MARK: - CJK detection

    func testCJKIdeographDetectionForCJKUnifiedExtension() {
        // 0x4E00 is the start of CJK Unified Ideographs
        let cjkChar = Character("\u{4E00}")
        XCTAssertTrue(cjkChar.isAliCloudCJKIdeograph)
    }

    func testCJKIdeographDetectionForLatinChar() {
        let latinChar = Character("A")
        XCTAssertFalse(latinChar.isAliCloudCJKIdeograph)
    }

    func testCJKIdeographDetectionForDigit() {
        let digit = Character("5")
        XCTAssertFalse(digit.isAliCloudCJKIdeograph)
    }

    func testCJKIdeographDetectionForCJKCompatibilityIdeograph() {
        // 0xF900 is in the CJK Compatibility Ideographs range
        let compat = Character("\u{F900}")
        XCTAssertTrue(compat.isAliCloudCJKIdeograph)
    }

    func testCJKIdeographDetectionForCJKExtensionA() {
        // 0x3400 is in CJK Extension A
        let extA = Character("\u{3400}")
        XCTAssertTrue(extA.isAliCloudCJKIdeograph)
    }

    // MARK: - Closing punctuation detection

    func testClosingPunctuationDetection() {
        for char in [",", ".", "!", "?", ";", ":", ")", "]", "}", "\"", "'"] {
            let c = Character(char)
            XCTAssertTrue(c.isAliCloudClosingPunctuation, "\(char) should be closing punctuation")
        }
    }

    func testOpeningPunctuationDetection() {
        for char in ["(", "[", "{", "/", "\"", "'"] {
            let c = Character(char)
            XCTAssertTrue(c.isAliCloudOpeningPunctuation, "\(char) should be opening punctuation")
        }
    }

    func testLatinCharIsNotPunctuation() {
        let c = Character("a")
        XCTAssertFalse(c.isAliCloudClosingPunctuation)
        XCTAssertFalse(c.isAliCloudOpeningPunctuation)
    }
}
