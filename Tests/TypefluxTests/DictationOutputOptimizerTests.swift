import Foundation
@testable import Typeflux
import XCTest

final class DictationOutputOptimizerTests: XCTestCase {
    func testOptimizeRemovesPeriodFromShortRawConversationalText() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("OK."), "OK")
        XCTAssertEqual(DictationOutputOptimizer.optimize("Thanks."), "Thanks")
        XCTAssertEqual(DictationOutputOptimizer.optimize("谢谢。"), "谢谢")
        XCTAssertEqual(DictationOutputOptimizer.optimize("我晚点回复你。"), "我晚点回复你")
    }

    func testOptimizePreservesExpressivePunctuation() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("Really?"), "Really?")
        XCTAssertEqual(DictationOutputOptimizer.optimize("真的吗？"), "真的吗？")
        XCTAssertEqual(DictationOutputOptimizer.optimize("Great!"), "Great!")
        XCTAssertEqual(DictationOutputOptimizer.optimize("太好了！"), "太好了！")
        XCTAssertEqual(DictationOutputOptimizer.optimize("等等……"), "等等……")
        XCTAssertEqual(DictationOutputOptimizer.optimize("Wait..."), "Wait...")
        XCTAssertEqual(DictationOutputOptimizer.optimize("Sounds good?!"), "Sounds good?!")
    }

    func testOptimizePreservesRewrittenText() {
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("谢谢。", origin: .rewritten),
            "谢谢。"
        )
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("OK.", origin: .rewritten),
            "OK."
        )
    }

    func testOptimizePreservesLongText() {
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("这是一个长度已经超过十五个字符的完整中文句子。"),
            "这是一个长度已经超过十五个字符的完整中文句子。"
        )
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("This sentence contains more than five words."),
            "This sentence contains more than five words."
        )
    }

    func testOptimizePreservesStructuredPeriods() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("Version 1.2."), "Version 1.2.")
        XCTAssertEqual(DictationOutputOptimizer.optimize("Visit example.com."), "Visit example.com.")
        XCTAssertEqual(DictationOutputOptimizer.optimize("U.S."), "U.S.")
        XCTAssertEqual(DictationOutputOptimizer.optimize("3.14."), "3.14.")
        XCTAssertEqual(DictationOutputOptimizer.optimize("好的。。"), "好的。。")
    }

    func testOptimizePreservesMultiSentenceAndMultilineText() {
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("Hello world. How are you?"),
            "Hello world. How are you?"
        )
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("First line.\nSecond line."),
            "First line.\nSecond line."
        )
    }

    func testOptimizePreservesLeadingAndTrailingWhitespace() {
        XCTAssertEqual(DictationOutputOptimizer.optimize(" Hello. "), " Hello ")
        XCTAssertEqual(DictationOutputOptimizer.optimize("  谢谢。"), "  谢谢")
        XCTAssertEqual(DictationOutputOptimizer.optimize("\tOK.\n"), "\tOK\n")
        XCTAssertEqual(DictationOutputOptimizer.optimize("  "), "  ")
        XCTAssertEqual(DictationOutputOptimizer.optimize(""), "")
    }

    func testDeduplicateRemovesPeriodAlreadyAtInsertionPoint() {
        let snapshot = makeSnapshot(text: "Hello 。world", insertionLocation: 6)

        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "好的。",
                against: snapshot
            ),
            "好的"
        )
    }

    func testDeduplicateTreatsFullWidthAndASCIIPunctuationAsEquivalent() {
        let snapshot = makeSnapshot(text: "Hello ?world", insertionLocation: 6)

        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "真的吗？",
                against: snapshot
            ),
            "真的吗"
        )
    }

    func testDeduplicatePreservesPunctuationWhenNoDuplicateExists() {
        let snapshot = makeSnapshot(text: "Hello world", insertionLocation: 6)

        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "真的吗？",
                against: snapshot
            ),
            "真的吗？"
        )
    }

    func testDeduplicateDoesNotCrossLineBoundariesOrRewriteMultilineText() {
        let nextLineSnapshot = makeSnapshot(text: "Hello \n。world", insertionLocation: 6)
        let sameLineSnapshot = makeSnapshot(text: "Hello 。world", insertionLocation: 6)

        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "好的。",
                against: nextLineSnapshot
            ),
            "好的。"
        )
        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "第一行。\n第二行。",
                against: sameLineSnapshot
            ),
            "第一行。\n第二行。"
        )
    }

    func testDeduplicatePreservesTextForUnreliableOrReplacingTarget() {
        var unreliable = makeSnapshot(text: "Hello 。world", insertionLocation: 6)
        unreliable.isFocusedTarget = false
        let replacing = CurrentInputTextSnapshot(
            text: "Hello 。world",
            selectedRange: CFRange(location: 6, length: 1),
            isEditable: true,
            isFocusedTarget: true
        )

        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "好的。",
                against: unreliable
            ),
            "好的。"
        )
        XCTAssertEqual(
            DictationOutputOptimizer.deduplicatingTrailingPunctuation(
                in: "好的。",
                against: replacing
            ),
            "好的。"
        )
    }

    private func makeSnapshot(text: String, insertionLocation: Int) -> CurrentInputTextSnapshot {
        CurrentInputTextSnapshot(
            text: text,
            selectedRange: CFRange(location: insertionLocation, length: 0),
            isEditable: true,
            isFocusedTarget: true
        )
    }
}
