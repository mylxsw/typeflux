import Foundation
import Testing
@testable import Typeflux

struct AskNumberConversionsTests {
    @Test(arguments: [("2024", "2024"), ("-5", "-5"), ("+00012.3400", "12.34"),
                      (".5", "0.5"), ("-0", "0"), ("１２３", "123"),
                      ("18446744073709551615", "18446744073709551615")])
    func `plain numbers offer conversions`(input: String, expected: String) throws {
        guard case let .calculation(result) = AskCalculator.read(input) else {
            Issue.record("No numeric conversion for \(input)"); return
        }
        #expect(result.isNumericInput)
        #expect(result.number?.plain == expected)
        let rows = try #require(AskQuickResults.resolve(text: input, previous: nil, chinese: true))
        #expect(!rows.formats.isEmpty && rows.rows.last == .askAI)
        #expect(rows.value(of: .calculation) == result.number?.copyText)
        #expect(AskQuickResults.resolve(text: input, previous: nil, chinese: true, numberConversions: false) == nil)
        #expect(AskQuickResults.resolve(text: input, previous: nil, chinese: true, calculator: false)?.calculation?.isNumericInput == true)
    }

    @Test func `integer conversions are exact and distinguish base64`() throws {
        let number = try #require(AskNumberConversions.read("255"))
        let rows = AskNumberConversions.formats(for: number)
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.value) })
        #expect(values[.binary] == "0b11111111")
        #expect(values[.octal] == "0o377")
        #expect(values[.hexadecimal] == "0xFF")
        #expect(values[.base36] == "73")
        #expect(values[.base64] == "3/")
        #expect(values[.base64Text] == "MjU1")
        #expect(values[.chineseNumber] == "贰佰伍拾伍")
        #expect(AskNumberConversions.convert("18446744073709551615", radix: 16) == "FFFFFFFFFFFFFFFF")
        #expect(AskNumberConversions.convert("18446744073709551616", radix: 16) == "10000000000000000")
        #expect(AskNumberConversions.convert("0", radix: 64) == "0")
        #expect(AskNumberConversions.convert("63", radix: 64) == "/")
        #expect(AskNumberConversions.convert("64", radix: 64) == "10")
    }

    @Test func `fractions never become integer radices or rounded chinese numbers`() throws {
        let number = try #require(AskNumberConversions.read("-1001.005"))
        let rows = AskNumberConversions.formats(for: number)
        #expect(rows.first?.value == "负壹仟零壹点零零伍")
        #expect(rows.first { $0.kind == .chineseAmount }?.value == "负壹仟零壹元零壹分")
        #expect(!rows.contains { [.binary, .octal, .hexadecimal, .base36, .base64].contains($0.kind) })
        #expect(rows.first { $0.kind == .grouped }?.value == "-1,001.005")
        let zero = try AskNumberConversions.formats(for: #require(AskNumberConversions.read("0")))
        #expect(zero.first?.value == "零")
        #expect(zero.first { $0.kind == .chineseAmount }?.value == "零元整")
    }

    @Test func `long digits remain exact and cannot become an overflowed amount`() throws {
        let input = String(repeating: "9", count: 200)
        let number = try #require(AskNumberConversions.read(input))
        #expect(number.plain == input)
        let rows = AskNumberConversions.formats(for: number)
        #expect(rows.contains { $0.kind == .hexadecimal })
        #expect(!rows.contains { $0.kind == .chineseAmount || $0.kind == .chineseNumber })
        let fraction = try #require(AskNumberConversions.read("0." + String(repeating: "1", count: 100)))
        #expect(!AskNumberConversions.formats(for: fraction).contains { $0.kind == .chineseAmount })
        #expect(AskNumberConversions.read(String(repeating: "1", count: 257)) == nil)
    }

    @Test(arguments: ["1 2", "1.2.3", "1.", "0xFF", "1e3", "--5", "", "NaN", "1+2", "1\n", " 1"])
    func `non decimals are left to other readers`(_ text: String) {
        #expect(AskNumberConversions.read(text) == nil)
    }
}
