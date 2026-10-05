import Foundation
import Testing
@testable import Typeflux

private func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite("Ask calculator formats")
struct AskCalculatorFormatsTests {
    @Test(arguments: [
        ("2", "贰元整"), ("100.05", "壹佰元零伍分"), ("1005", "壹仟零伍元整"), ("10000", "壹万元整"),
        ("100000000", "壹亿元整"), ("0.5", "伍角整"), ("0.05", "伍分"), ("0.55", "伍角伍分"), ("10", "壹拾元整"),
        ("1050", "壹仟零伍拾元整"), ("100001", "壹拾万零壹元整"), ("100000001", "壹亿零壹元整"),
        ("110000000", "壹亿壹仟万元整"), ("101000000", "壹亿零壹佰万元整"), ("1000000000000", "壹万亿元整"),
        ("2469135.78", "贰佰肆拾陆万玖仟壹佰叁拾伍元柒角捌分"), ("-3.2", "负叁元贰角整"), ("1.999", "贰元整"),
        ("9999999999999999.99", "玖仟玖佰玖拾玖万玖仟玖佰玖拾玖亿玖仟玖佰玖拾玖万玖仟玖佰玖拾玖元玖角玖分")
    ])
    func chineseAmounts(value: String, expected: String) {
        #expect(AskCalculatorFormats.chineseAmount(decimal(value)) == expected, "\(value)")
    }

    @Test func chineseAmountsNeedAnAmount() {
        #expect(AskCalculatorFormats.chineseAmount(0) == nil)
        #expect(AskCalculatorFormats.chineseAmount(decimal("0.001")) == nil, "rounds to zero")
        #expect(AskCalculatorFormats.chineseAmount(decimal("10000000000000000")) == nil)
    }

    @Test func englishAmounts() {
        #expect(AskCalculatorFormats.englishAmount(2) == "SAY US DOLLARS TWO ONLY")
        #expect(AskCalculatorFormats.englishAmount(decimal("2469135.78")) == "SAY US DOLLARS TWO MILLION FOUR HUNDRED "
            + "SIXTY-NINE THOUSAND ONE HUNDRED THIRTY-FIVE AND CENTS SEVENTY-EIGHT ONLY")
        #expect(AskCalculatorFormats.englishAmount(decimal("0.5")) == "SAY US DOLLARS ZERO AND CENTS FIFTY ONLY")
        #expect(AskCalculatorFormats.englishAmount(decimal("-2")) == nil)
        #expect(AskCalculatorFormats.englishAmount(0) == nil)
        #expect(AskCalculatorFormats.englishInteger(1_000_000_000_015) == "ONE TRILLION FIFTEEN")
        #expect(AskCalculatorFormats.englishInteger(1_000_000_000_000_000) == "ONE QUADRILLION")
        #expect(AskCalculatorFormats.englishInteger(110) == "ONE HUNDRED TEN")
        #expect(AskCalculatorFormats.englishInteger(40) == "FORTY")
    }

    @Test func rowsFollowTheInterfaceLanguage() {
        let number = AskCalculatorNumber(decimal("2469135.78"))
        #expect(AskCalculatorFormats.formats(for: number, radix: false, chinese: true).map(\.kind)
            == [.chineseAmount, .grouped, .englishAmount])
        #expect(AskCalculatorFormats.formats(for: number, radix: false, chinese: false).map(\.kind)
            == [.grouped, .englishAmount, .chineseAmount])
        let grouped = AskCalculatorFormats.formats(for: number, radix: false, chinese: false)[0]
        #expect(grouped.value == "2,469,135.78")
        #expect(grouped.id == "grouped")
        #expect(!grouped.kind.title.isEmpty)
    }

    @Test func smallValuesSkipTheThousandsRow() {
        let rows = AskCalculatorFormats.formats(for: AskCalculatorNumber(2), radix: false, chinese: true)
        #expect(rows.map(\.kind) == [.chineseAmount, .englishAmount])
    }

    @Test func radixInputAddsHexadecimalAndBinaryFirst() {
        let rows = AskCalculatorFormats.formats(for: AskCalculatorNumber(256), radix: true, chinese: true)
        #expect(rows.map(\.kind) == [.hexadecimal, .binary, .chineseAmount])
        #expect(rows[0].value == "0x100")
        #expect(rows[1].value == "0b100000000")
        let negative = AskCalculatorFormats.formats(for: AskCalculatorNumber(-255), radix: true, chinese: false)
        #expect(negative.first?.value == "-0xFF")
        let fraction = AskCalculatorFormats.formats(for: AskCalculatorNumber(decimal("2.5")), radix: true, chinese: false)
        #expect(!fraction.contains { $0.kind == .hexadecimal })
    }

    @Test func scientificResultsGetNoAmounts() {
        let rows = AskCalculatorFormats.formats(for: AskCalculatorNumber(decimal("1e20")), radix: false, chinese: true)
        #expect(rows.isEmpty)
    }
}

@Suite("Ask calculator number")
struct AskCalculatorNumberTests {
    @Test func roundsToFifteenSignificantDigits() {
        #expect(AskCalculatorNumber(decimal("0.1") + decimal("0.2")).plain == "0.3")
        #expect(AskCalculatorNumber(1 / decimal("3")).plain == "0.333333333333333")
        #expect(AskCalculatorNumber(decimal("9.99999999999999999")).plain == "10")
        #expect(AskCalculatorNumber(decimal("999999999999999.9")).plain == "1000000000000000")
        #expect(AskCalculatorNumber(decimal("-1234.5000")).plain == "-1234.5")
        #expect(AskCalculatorNumber(0).plain == "0")
        #expect(AskCalculatorNumber(decimal("-0.0001")).plain == "-0.0001")
    }

    @Test func spellings() {
        let number = AskCalculatorNumber(decimal("-1234567.5"))
        #expect(number.grouped == "-1,234,567.5")
        #expect(number.displayText == "-1,234,567.5")
        #expect(number.copyText == "-1234567.5")
        #expect(!number.isInteger)
        #expect(AskCalculatorNumber(123).grouped == "123")
        #expect(AskCalculatorNumber(1000).grouped == "1,000")
        #expect(AskCalculatorNumber(0).grouped == "0")
        #expect(AskCalculatorNumber(0).scientific == "0e0")
        #expect(AskCalculatorNumber(0).isZero)
    }

    @Test func extremesUseScientificNotation() {
        let large = AskCalculatorNumber(decimal("1e15"))
        #expect(large.prefersScientific)
        #expect(large.copyText == "1e15")
        #expect(large.displayText == "1 × 10¹⁵")
        #expect(large.plain == "1000000000000000")
        let small = AskCalculatorNumber(decimal("-0.00000015"))
        #expect(small.prefersScientific)
        #expect(small.copyText == "-1.5e-7")
        #expect(small.displayText == "-1.5 × 10⁻⁷")
        #expect(!AskCalculatorNumber(decimal("0.000001")).prefersScientific)
        #expect(!AskCalculatorNumber(decimal("999999999999999")).prefersScientific)
    }
}
