import Foundation

/// Another way to write a result, offered as a row that copies on its own.
struct AskCalculatorFormat: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case chineseAmount, grouped, englishAmount, hexadecimal, binary
        case chineseNumber, octal, base36, base64, base64Text, scientific

        var title: String { L("ask.quick.format." + rawValue) }
    }

    var kind: Kind
    var value: String

    var id: String { kind.rawValue }
}

enum AskCalculatorFormats {
    static let maximumRows = 3
    /// Amounts in words stop below ten thousand trillion (万亿 × 10⁴).
    static let amountLimit = Decimal(string: "10000000000000000")!

    /// The rows under a result, in the order that suits the interface language.
    static func formats(for number: AskCalculatorNumber, radix: Bool, chinese: Bool) -> [AskCalculatorFormat] {
        var rows: [AskCalculatorFormat] = []
        if radix, number.isInteger, let integer = Int64(number.plain) {
            let sign = integer < 0 ? "-" : ""
            let magnitude = integer.magnitude
            rows.append(.init(kind: .hexadecimal, value: sign + "0x" + String(magnitude, radix: 16, uppercase: true)))
            rows.append(.init(kind: .binary, value: sign + "0b" + String(magnitude, radix: 2)))
        }
        let chineseRow = chineseAmount(number.decimal).map { AskCalculatorFormat(kind: .chineseAmount, value: $0) }
        let groupedRow = !number.prefersScientific && number.decimal.magnitude >= 1000
            ? AskCalculatorFormat(kind: .grouped, value: number.grouped) : nil
        let englishRow = englishAmount(number.decimal).map { AskCalculatorFormat(kind: .englishAmount, value: $0) }
        let ordered = chinese ? [chineseRow, groupedRow, englishRow] : [groupedRow, englishRow, chineseRow]
        rows += ordered.compactMap { $0 }
        return Array(rows.prefix(maximumRows))
    }

    // MARK: - Chinese amount (人民币大写)

    private static let chineseDigits: [String] = ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]

    /// "贰佰肆拾陆万玖仟壹佰叁拾伍元柒角捌分", rounded to the fen (分).
    static func chineseAmount(_ value: Decimal) -> String? {
        guard let (negative, yuan, cents) = amountParts(value) else { return nil }
        let jiao = cents / 10, fen = cents % 10
        var text = negative ? "负" : ""
        if yuan > 0 { text += chineseInteger(yuan) + "元" }
        if jiao > 0 {
            text += chineseDigits[Int(jiao)] + "角"
        } else if yuan > 0, fen > 0 {
            text += "零"
        }
        if fen > 0 { text += chineseDigits[Int(fen)] + "分" } else { text += "整" }
        return text
    }

    /// Up to 9999 9999 9999 9999: the part above 亿, then the part below it.
    static func chineseInteger(_ value: UInt64) -> String {
        let high = value / 100_000_000, low = value % 100_000_000
        guard high > 0 else { return chineseBelowYi(low) }
        var text = chineseBelowYi(high) + "亿"
        if low > 0 { text += (low < 10_000_000 ? "零" : "") + chineseBelowYi(low) }
        return text
    }

    private static func chineseBelowYi(_ value: UInt64) -> String {
        let high = value / 10000, low = value % 10000
        guard high > 0 else { return chineseGroup(low) }
        var text = chineseGroup(high) + "万"
        if low > 0 { text += (low < 1000 ? "零" : "") + chineseGroup(low) }
        return text
    }

    /// 1 to 9999, writing a single 零 for each run of inner zeros.
    private static func chineseGroup(_ value: UInt64) -> String {
        var text = ""
        var pendingZero = false
        for (place, unit) in [(UInt64(1000), "仟"), (100, "佰"), (10, "拾"), (1, "")] {
            let digit = Int(value / place % 10)
            if digit == 0 {
                if !text.isEmpty { pendingZero = true }
                continue
            }
            if pendingZero { text += "零"; pendingZero = false }
            text += chineseDigits[digit] + unit
        }
        return text
    }

    // MARK: - English amount

    private static let ones = ["", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN",
                               "ELEVEN", "TWELVE", "THIRTEEN", "FOURTEEN", "FIFTEEN", "SIXTEEN", "SEVENTEEN",
                               "EIGHTEEN", "NINETEEN"]
    private static let tens = ["", "", "TWENTY", "THIRTY", "FORTY", "FIFTY", "SIXTY", "SEVENTY", "EIGHTY", "NINETY"]
    private static let scales = ["", "THOUSAND", "MILLION", "BILLION", "TRILLION", "QUADRILLION"]

    /// "SAY US DOLLARS TWO AND CENTS FIFTY ONLY", the wording used on invoices and cheques.
    static func englishAmount(_ value: Decimal) -> String? {
        guard let (negative, dollars, cents) = amountParts(value), !negative else { return nil }
        var text = "SAY US DOLLARS " + englishInteger(dollars)
        if cents > 0 { text += " AND CENTS " + englishInteger(cents) }
        return text + " ONLY"
    }

    static func englishInteger(_ value: UInt64) -> String {
        guard value > 0 else { return "ZERO" }
        var groups: [String] = []
        var remaining = value
        var scale = 0
        while remaining > 0 {
            let group = Int(remaining % 1000)
            if group > 0 {
                groups.insert(englishGroup(group) + (scales[scale].isEmpty ? "" : " " + scales[scale]), at: 0)
            }
            remaining /= 1000
            scale += 1
        }
        return groups.joined(separator: " ")
    }

    private static func englishGroup(_ value: Int) -> String {
        var words: [String] = []
        if value >= 100 { words.append(ones[value / 100] + " HUNDRED") }
        let rest = value % 100
        if rest >= 20 {
            words.append(tens[rest / 10] + (rest % 10 > 0 ? "-" + ones[rest % 10] : ""))
        } else if rest > 0 {
            words.append(ones[rest])
        }
        return words.joined(separator: " ")
    }

    // MARK: - Shared

    /// Splits a non-zero amount below the limit into whole units and cents, rounding half up.
    private static func amountParts(_ value: Decimal) -> (negative: Bool, units: UInt64, cents: UInt64)? {
        var input = value.magnitude
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        guard !rounded.isZero, rounded < amountLimit else { return nil }
        // NSDecimalNumber's integer accessors lose digits on large values; the description does not.
        guard let totalCents = UInt64((rounded * 100).description) else { return nil }
        return (value < 0, totalCents / 100, totalCents % 100)
    }
}
