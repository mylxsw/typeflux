import Foundation
import Testing
@testable import Typeflux

/// Reads `text` and returns what the launcher would show as the result line.
private func shown(_ text: String) -> String? {
    guard case let .calculation(calculation) = AskCalculator.read(text) else { return nil }
    switch calculation.outcome {
    case let .success(number): return number.plain
    case let .failure(error): return "error:\(error)"
    }
}

@Suite("Ask calculator detection")
struct AskCalculatorDetectionTests {
    @Test(arguments: [
        ("1+1", "2"), ("(3+4)*5", "35"), ("pi*2", "6.28318530717959"), ("１＋１", "2"),
        ("1+1=", "2"), ("2 x 3", "6"), ("6÷4", "1.5"), ("3×4", "12"), ("2**10", "1024"),
        ("1,234+1", "1235"), ("sqrt(16)", "4"), ("-5+2", "-3"), ("50%", "0.5"), ("5!", "120"),
        ("（1＋2）×3", "9"), ("1e3+1", "1001"), (".5+.5", "1"), ("2024-1990", "34"), ("10/4", "2.5")
    ])
    func recognizesArithmetic(text: String, expected: String) {
        #expect(shown(text) == expected, "\(text)")
    }

    @Test(arguments: [
        "2024", "-5", "pi", "e", "hello", "hello 1+1", "1+1 是多少", "2024-10-05", "2024/10/5", "2024-10",
        "10/5/2024", "138-1234-5678", "010-12345678", "1.2.3", "192.168.0.1", "", "   ", "1+1\n2+2",
        "foo(1)", "1,0000+1", "1 2", "()", "max(1,,2)", "/model"
    ])
    func leavesOtherTextToTheAI(text: String) {
        #expect(AskCalculator.read(text) == .notExpression, "\(text)")
    }

    @Test func unfinishedArithmeticIsIncomplete() {
        #expect(AskCalculator.read("12*3+") == .incomplete(expression: "12 × 3 +"))
        #expect(AskCalculator.read("(1+2") == .incomplete(expression: "(1 + 2"))
        #expect(AskCalculator.read("sqrt(") == .incomplete(expression: "sqrt("))
        #expect(AskCalculator.read("sin") == .incomplete(expression: "sin"))
        #expect(AskCalculator.read("max(1,") == .incomplete(expression: "max(1,"))
    }

    @Test func overlongTextIsLeftAlone() {
        let text = Array(repeating: "1+", count: 200).joined() + "1"
        #expect(AskCalculator.read(text) == .notExpression)
    }

    @Test func deepNestingIsRejectedInsteadOfRecursingForever() {
        let deep = String(repeating: "(", count: 80) + "1" + String(repeating: ")", count: 80) + "+1"
        #expect(AskCalculator.read(deep) == .notExpression)
        let fine = String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20) + "+1"
        #expect(shown(fine) == "2")
        #expect(AskCalculator.read(String(repeating: "-", count: 100) + "1+1") == .notExpression)
    }

    @Test func theExpressionIsTidiedForDisplay() throws {
        guard case let .calculation(calculation) = AskCalculator.read("1234567.89*2") else { Issue.record("no result"); return }
        #expect(calculation.expression == "1234567.89 × 2")
        guard case let .calculation(other) = AskCalculator.read("-2^2/(3-1)%  mod 4") else { Issue.record("no result"); return }
        #expect(other.expression == "-2^2 ÷ (3 - 1)% mod 4")
        guard case let .calculation(call) = AskCalculator.read("max(1,2)*-3") else { Issue.record("no result"); return }
        #expect(call.expression == "max(1, 2) × -3")
    }

    @Test func radixInputIsNoted() {
        guard case let .calculation(hex) = AskCalculator.read("0xff+1") else { Issue.record("no result"); return }
        #expect(hex.radix)
        #expect(hex.number?.plain == "256")
        guard case let .calculation(plain) = AskCalculator.read("255+1") else { Issue.record("no result"); return }
        #expect(!plain.radix)
    }

    @Test func lookalikesAreRecognized() {
        #expect(AskCalculator.looksLikeSomethingElse("2024-10-05"))
        #expect(AskCalculator.looksLikeSomethingElse("138 - 1234 - 5678"))
        #expect(!AskCalculator.looksLikeSomethingElse("2024-1990"))
    }
}

@Suite("Ask calculator evaluation")
struct AskCalculatorEvaluationTests {
    @Test(arguments: [
        ("0.1+0.2", "0.3"), ("200+10%", "220"), ("200-10%", "180"), ("200*10%", "20"), ("1/3", "0.333333333333333"),
        ("2/3", "0.666666666666667"), ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"),
        ("2^0.5", "1.4142135623731"), ("7 mod 3", "1"), ("-7 mod 3", "-1"), ("7.5 mod 2", "1.5"), ("0!", "1"),
        ("abs(-3)", "3"), ("floor(2.7)", "2"), ("floor(-2.1)", "-3"), ("ceil(2.1)", "3"), ("ceil(-2.7)", "-2"),
        ("round(2.5)", "3"), ("round(-2.5)", "-3"), ("round(3.14159, 2)", "3.14"), ("min(3,1,2)", "1"), ("max(3,1,2)", "3"),
        ("ln(e)", "1"), ("log(1000)", "3"), ("log2(8)", "3"), ("sin(30°)", "0.5"), ("cos(0)", "1"), ("sin(pi)", "0"),
        ("tan(45°)", "1"), ("asin(1)*2", "3.14159265358979"), ("acos(1)+1", "1"), ("atan(1)*4", "3.14159265358979"),
        ("π*1", "3.14159265358979"), ("e*1", "2.71828182845905"), ("0b101+1", "6"), ("+3*2", "6"), ("--3+0", "3"),
        ("10%+5", "5.1"), ("2*3!", "12"), ("1.5e3*2", "3000"), ("90°*1", "1.5707963267949")
    ])
    func computes(text: String, expected: String) {
        #expect(shown(text) == expected, "\(text)")
    }

    @Test(arguments: [
        ("1/0", AskCalculatorError.divisionByZero), ("5 mod 0", .divisionByZero), ("0^-1", .divisionByZero),
        ("sqrt(-1)", .domain), ("ln(0)", .domain), ("log(-1)", .domain), ("asin(2)", .domain), ("acos(-2)+0", .domain),
        ("(-8)^(1/3)", .domain), ("2.5!", .domain), ("(-1)!", .domain), ("171!", .outOfRange), ("120!", .outOfRange),
        ("10^200", .outOfRange), ("2^5000", .outOfRange), ("round(1, 0.5)", .domain), ("round(1, 40)", .domain)
    ])
    func reportsWhyThereIsNoValue(text: String, error: AskCalculatorError) {
        #expect(shown(text) == "error:\(error)", "\(text)")
    }

    @Test func errorsHaveMessages() {
        for error in [AskCalculatorError.divisionByZero, .domain, .outOfRange] {
            #expect(!error.message.isEmpty)
        }
    }

    @Test func largeResultsRoundToFifteenDigits() {
        #expect(shown("2^64") == "18446744073709600000")
        guard case let .calculation(calculation) = AskCalculator.read("2^64") else { Issue.record("no result"); return }
        #expect(calculation.number?.prefersScientific == true)
        #expect(calculation.number?.displayText == "1.84467440737096 × 10¹⁹")
        #expect(shown("99999999*99999999") == "9999999800000000")
    }
}

@Suite("Ask calculator lexer")
struct AskCalculatorLexerTests {
    @Test func normalizesWhatInputMethodsType() {
        #expect(AskCalculatorLexer.normalize("１２＋３４") == "12+34")
        #expect(AskCalculatorLexer.normalize(" 3×4÷2−1 = ") == "3*4/2-1")
        #expect(AskCalculatorLexer.normalize("1。5") == "1.5")
        #expect(AskCalculatorLexer.normalize("2**3==") == "2^3")
        #expect(AskCalculatorLexer.normalize("　１") == "1")
    }

    @Test func commasInsideCallsSeparateArguments() throws {
        let tokens = try AskCalculatorLexer.tokenize("max(1,234)")
        #expect(tokens.filter { if case .number = $0 { true } else { false } }.count == 2)
        let grouped = try AskCalculatorLexer.tokenize("1,234,567")
        #expect(grouped.count == 1)
        #expect(AskCalculator.read("1,234,56") == .notExpression, "a short last group is not a thousands separator")
        #expect(throws: AskCalculatorLexer.Failure.self) { try AskCalculatorLexer.tokenize("1+#") }
        #expect(throws: AskCalculatorLexer.Failure.self) { try AskCalculatorLexer.tokenize("0xZZ") }
        #expect(throws: AskCalculatorLexer.Failure.self) { try AskCalculatorLexer.tokenize("0x") }
    }

    @Test func numbersKeepTheirWrittenForm() throws {
        #expect(try AskCalculatorLexer.tokenize("1,234.50") == [.number(Decimal(string: "1234.5")!, text: "1234.50", radix: false)])
        #expect(try AskCalculatorLexer.tokenize("0XFF") == [.number(255, text: "0xff", radix: true)])
        #expect(try AskCalculatorLexer.tokenize("5.") == [.number(5, text: "5", radix: false)])
        #expect(try AskCalculatorLexer.tokenize("2e") == [.number(2, text: "2", radix: false), .identifier("e")])
        #expect(try AskCalculatorLexer.tokenize("7 MOD 2") == [.number(7, text: "7", radix: false), .symbol("m"),
                                                                .number(2, text: "2", radix: false)])
    }
}
