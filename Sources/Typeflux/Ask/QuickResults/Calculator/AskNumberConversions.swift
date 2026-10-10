import Foundation

/// Plain decimals use exact digit strings, including integers larger than UInt64.
enum AskNumberConversions {
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(pattern: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z"#)
    /// Radix 64 is positional notation, not RFC 4648 encoding of bytes.
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/")

    static func read(_ text: String) -> AskCalculatorNumber? {
        guard text.count <= AskCalculatorLexer.maximumLength,
              pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
        return AskCalculatorNumber(numericInput: text)
    }

    static func formats(for number: AskCalculatorNumber) -> [AskCalculatorFormat] {
        var rows: [AskCalculatorFormat] = []
        if let words = chineseNumber(number) { rows.append(.init(kind: .chineseNumber, value: words)) }
        // Decimal supports at most 38 significant digits. Never turn an oversized input into a rounded amount.
        if number.digits.count <= 38, number.pointPosition <= 16, number.pointPosition >= -38 {
            if number.isZero {
                rows.append(.init(kind: .chineseAmount, value: "零元整"))
            } else if let amount = AskCalculatorFormats.chineseAmount(number.decimal) {
                rows.append(.init(kind: .chineseAmount, value: amount))
            }
        }
        if number.isInteger {
            let digits = number.plain.replacingOccurrences(of: "-", with: "")
            let sign = number.negative ? "-" : ""
            for (kind, radix, prefix) in [(AskCalculatorFormat.Kind.binary, 2, "0b"), (.octal, 8, "0o"),
                                          (.hexadecimal, 16, "0x"), (.base36, 36, ""), (.base64, 64, "")] {
                rows.append(.init(kind: kind, value: sign + prefix + convert(digits, radix: radix)))
            }
        }
        if number.pointPosition > 3 { rows.append(.init(kind: .grouped, value: number.grouped)) }
        rows.append(.init(kind: .scientific, value: number.scientific))
        rows.append(.init(kind: .base64Text, value: Data(number.plain.utf8).base64EncodedString()))
        return rows
    }

    /// Repeated division keeps every input digit; no floating point or machine-integer limit.
    static func convert(_ decimal: String, radix: Int) -> String {
        precondition((2 ... alphabet.count).contains(radix))
        var digits = decimal.compactMap(\.wholeNumberValue)
        var result: [Character] = []
        repeat {
            var quotient: [Int] = []
            var remainder = 0
            for digit in digits {
                let value = remainder * 10 + digit
                let next = value / radix
                if next != 0 || !quotient.isEmpty { quotient.append(next) }
                remainder = value % radix
            }
            result.append(alphabet[remainder])
            digits = quotient
        } while !digits.isEmpty
        return String(result.reversed())
    }

    static func chineseNumber(_ number: AskCalculatorNumber) -> String? {
        let parts = number.plain.replacingOccurrences(of: "-", with: "").split(separator: ".")
        guard let integer = UInt64(parts[0]), integer < 10_000_000_000_000_000 else { return nil }
        var text = (number.negative ? "负" : "") + (integer == 0 ? "零" : AskCalculatorFormats.chineseInteger(integer))
        if parts.count > 1 {
            let words = Array("零壹贰叁肆伍陆柒捌玖")
            text += "点" + String(parts[1].compactMap { $0.wholeNumberValue.map { words[$0] } })
        }
        return text
    }
}
