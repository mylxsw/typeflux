import Foundation

/// A calculator result rounded to the digits worth showing, and its spellings.
/// Rounding happens once here, so what is shown is exactly what is copied.
struct AskCalculatorNumber: Equatable {
    static let significantDigits = 15
    private static let posix = Locale(identifier: "en_US_POSIX")

    let negative: Bool
    /// Significant digits without leading or trailing zeros; empty for zero.
    let digits: [Character]
    /// Where the decimal point sits relative to `digits`: the value is
    /// `0.digits × 10^pointPosition`, so 123.4 has digits "1234" and position 3.
    let pointPosition: Int

    /// Validated decimal digits, preserved exactly for numeric conversions.
    init(numericInput: String) {
        let unsigned = numericInput.hasPrefix("-") || numericInput.hasPrefix("+")
            ? String(numericInput.dropFirst()) : numericInput
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(parts.joined())
        var point = parts[0].count
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        self.digits = digits
        negative = !digits.isEmpty && numericInput.hasPrefix("-")
        pointPosition = digits.isEmpty ? 0 : point
    }

    init(_ value: Decimal, significantDigits: Int = Self.significantDigits) {
        let magnitude = value.magnitude
        var digits = Array(magnitude.significand.description)
        var exponent = Int(magnitude.exponent)
        while digits.first == "0" { digits.removeFirst() }
        if digits.count > significantDigits {
            let roundUp = digits[significantDigits] >= "5"
            exponent += digits.count - significantDigits
            digits = Array(digits.prefix(significantDigits))
            if roundUp {
                var index = digits.count - 1
                while index >= 0 {
                    if digits[index] == "9" { digits[index] = "0"; index -= 1; continue }
                    digits[index] = Character(String(digits[index].wholeNumberValue! + 1))
                    break
                }
                if index < 0 { digits.insert("1", at: 0); digits.removeLast(); exponent += 1 }
            }
        }
        while digits.last == "0" { digits.removeLast(); exponent += 1 }
        self.digits = digits
        self.negative = !digits.isEmpty && value < 0
        pointPosition = digits.isEmpty ? 0 : digits.count + exponent
    }

    var isZero: Bool { digits.isEmpty }
    var isInteger: Bool { pointPosition >= digits.count }

    /// Very large and very small values read better in scientific notation.
    var prefersScientific: Bool {
        !isZero && (pointPosition > Self.significantDigits || pointPosition < -5)
    }

    /// The rounded value.
    var decimal: Decimal { Decimal(string: plain, locale: Self.posix) ?? 0 }

    /// Digits only, e.g. "-1234.5"; never scientific.
    var plain: String {
        guard !isZero else { return "0" }
        let (integer, fraction) = parts
        return (negative ? "-" : "") + integer + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// With thousands separators, e.g. "-1,234.5".
    var grouped: String {
        guard !isZero else { return "0" }
        let (integer, fraction) = parts
        var groupedInteger = ""
        for (offset, char) in integer.enumerated() {
            if offset > 0, (integer.count - offset) % 3 == 0 { groupedInteger.append(",") }
            groupedInteger.append(char)
        }
        return (negative ? "-" : "") + groupedInteger + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// "1.5e-7" for pasting into other apps.
    var scientific: String {
        let (mantissa, exponent) = scientificParts
        return mantissa + "e" + String(exponent)
    }

    /// "1.5 × 10⁻⁷" for reading.
    var scientificDisplay: String {
        let (mantissa, exponent) = scientificParts
        let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻"
        ]
        return mantissa + " × 10" + String(String(exponent).compactMap { superscripts[$0] })
    }

    /// What Return copies: plain digits, or scientific notation when that is how it is shown.
    var copyText: String { prefersScientific ? scientific : plain }
    /// The large result line.
    var displayText: String { prefersScientific ? scientificDisplay : grouped }

    private var parts: (integer: String, fraction: String) {
        if pointPosition <= 0 {
            return ("0", String(repeating: "0", count: -pointPosition) + String(digits))
        }
        if pointPosition >= digits.count {
            return (String(digits) + String(repeating: "0", count: pointPosition - digits.count), "")
        }
        return (String(digits.prefix(pointPosition)), String(digits.dropFirst(pointPosition)))
    }

    private var scientificParts: (mantissa: String, exponent: Int) {
        guard !isZero else { return ("0", 0) }
        let tail = digits.dropFirst()
        let mantissa = (negative ? "-" : "") + String(digits[0]) + (tail.isEmpty ? "" : "." + String(tail))
        return (mantissa, pointPosition - 1)
    }
}
