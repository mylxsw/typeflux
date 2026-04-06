import XCTest
@testable import Typeflux

final class DictationOutputOptimizerTests: XCTestCase {
    func testOptimizeRemovesTrailingPeriodFromShortSentence() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("Hello world."), "Hello world")
    }

    func testOptimizeRemovesTrailingChinesePeriodFromShortSentence() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("你好。"), "你好")
    }

    func testOptimizeLeavesTextUnchangedWhenNoTrailingPunctuationExists() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("Hello world"), "Hello world")
    }

    func testOptimizeLeavesMultiSentenceTextUnchanged() {
        XCTAssertEqual(
            DictationOutputOptimizer.optimize("Hello world. How are you?"),
            "Hello world. How are you?",
        )
    }

    func testOptimizeLeavesLongSentenceUnchanged() {
        let input = "This is a fairly long sentence intended to exceed the short sentence limit so the optimizer should not strip the trailing period."
        XCTAssertEqual(DictationOutputOptimizer.optimize(input), input)
    }

    func testOptimizeLeavesNewlineSeparatedTextUnchanged() {
        let input = "First line.\nSecond line."
        XCTAssertEqual(DictationOutputOptimizer.optimize(input), input)
    }

    func testOptimizeRemovesRepeatedTrailingSentencePunctuation() {
        XCTAssertEqual(DictationOutputOptimizer.optimize("Sounds good?!"), "Sounds good")
    }

    func testOptimizePreservesLeadingAndTrailingWhitespaces() {
        XCTAssertEqual(DictationOutputOptimizer.optimize(" Hello world. "), " Hello world ")
        XCTAssertEqual(DictationOutputOptimizer.optimize("  你好。"), "  你好")
        XCTAssertEqual(DictationOutputOptimizer.optimize("\tSounds good?!\n"), "\tSounds good\n")
        XCTAssertEqual(DictationOutputOptimizer.optimize("  "), "  ")
    }
}
