import Foundation

/// One piece of a calculator expression.
enum AskCalculatorToken: Equatable {
    /// `text` is the number as written, without thousands separators.
    case number(Decimal, text: String, radix: Bool)
    case identifier(String)
    /// `+ - * / ^ % ! ° ( ) ,` and `m` for the `mod` operator.
    case symbol(Character)
}

/// Turns the launcher's text into tokens. Full-width characters typed with a
/// Chinese input method, `×`, `÷` and a trailing `=` are accepted as well.
enum AskCalculatorLexer {
    enum Failure: Error, Equatable {
        case unexpected(Character)
    }

    /// Longest text that is still worth reading as an expression.
    static let maximumLength = 256

    /// Folds full-width and typographic characters into the ASCII the lexer reads.
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01 ... 0xFF5E: scalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0x3000: scalars.append(" ")
            case 0x3002: scalars.append(".") // 。
            case 0x00D7, 0x2715, 0x2716, 0x22C5, 0x00B7: scalars.append("*") // × ✕ ✖ ⋅ ·
            case 0x00F7, 0x2215: scalars.append("/") // ÷ ∕
            case 0x2212, 0x2013, 0x2014: scalars.append("-") // − – —
            default: scalars.append(scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespaces)
        result = result.replacingOccurrences(of: "**", with: "^")
        while result.hasSuffix("=") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func tokenize(_ normalized: String) throws -> [AskCalculatorToken] {
        let chars = Array(normalized)
        var tokens: [AskCalculatorToken] = []
        // Whether each open parenthesis belongs to a function call, where commas separate arguments.
        var calls: [Bool] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace { index += 1; continue }
            if char.isASCIIDigit || (char == "." && chars.at(index + 1)?.isASCIIDigit == true) {
                let thousands = calls.last != true
                let (token, next) = try number(chars, from: index, thousands: thousands)
                tokens.append(token)
                index = next
                continue
            }
            if char == "x" || char == "X", endsOperand(tokens), startsOperand(chars, after: index) {
                tokens.append(.symbol("*"))
                index += 1
                continue
            }
            if char.isASCIILetter || char == "π" {
                var end = index
                while end < chars.count, chars[end].isASCIILetter || chars[end].isASCIIDigit || chars[end] == "π" { end += 1 }
                let word = String(chars[index ..< end]).lowercased()
                tokens.append(word == "mod" ? .symbol("m") : .identifier(word))
                index = end
                continue
            }
            switch char {
            case "+", "-", "*", "/", "^", "%", "!", "°", ",", ")":
                if char == ")" { _ = calls.popLast() }
                tokens.append(.symbol(char))
            case "(":
                if case .identifier = tokens.last { calls.append(true) } else { calls.append(false) }
                tokens.append(.symbol(char))
            default:
                throw Failure.unexpected(char)
            }
            index += 1
        }
        return tokens
    }

    private static func endsOperand(_ tokens: [AskCalculatorToken]) -> Bool {
        switch tokens.last {
        case .number?: return true
        case .symbol(")")?: return true
        default: return false
        }
    }

    private static func startsOperand(_ chars: [Character], after index: Int) -> Bool {
        var next = index + 1
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        guard let char = chars.at(next) else { return false }
        return char.isASCIIDigit || char == "." || char == "("
    }

    /// Reads a decimal, `0x…` or `0b…` number. Commas count as thousands
    /// separators only outside function calls and only in groups of three.
    private static func number(_ chars: [Character], from start: Int,
                               thousands: Bool) throws -> (AskCalculatorToken, Int) {
        if chars[start] == "0", let marker = chars.at(start + 1), marker == "x" || marker == "X" || marker == "b" || marker == "B" {
            let radix = marker == "x" || marker == "X" ? 16 : 2
            var end = start + 2
            while end < chars.count, chars[end].isASCIIAlphanumeric { end += 1 }
            let digits = String(chars[(start + 2) ..< end])
            guard !digits.isEmpty, let value = UInt64(digits, radix: radix), value <= UInt64(Int64.max) else {
                throw Failure.unexpected(marker)
            }
            return (.number(Decimal(value), text: String(chars[start ..< end]).lowercased(), radix: true), end)
        }
        var text = ""
        var index = start
        var groupLength = 0
        var grouped = false
        while index < chars.count {
            let char = chars[index]
            if char.isASCIIDigit {
                text.append(char); groupLength += 1; index += 1
            } else if char == ",", thousands, !text.isEmpty, isThousandsGroup(chars, at: index),
                      grouped ? groupLength == 3 : (1 ... 3).contains(groupLength) {
                grouped = true; groupLength = 0; index += 1
            } else {
                break
            }
        }
        if grouped, groupLength != 3 { throw Failure.unexpected(",") }
        if chars.at(index) == ".", chars.at(index + 1)?.isASCIIDigit == true || !text.isEmpty {
            text.append("."); index += 1
            while index < chars.count, chars[index].isASCIIDigit { text.append(chars[index]); index += 1 }
        }
        if let marker = chars.at(index), marker == "e" || marker == "E" {
            var end = index + 1
            if let sign = chars.at(end), sign == "+" || sign == "-" { end += 1 }
            let digitsStart = end
            while end < chars.count, chars[end].isASCIIDigit { end += 1 }
            // "2e" stays a number followed by the constant e.
            if end > digitsStart, chars.at(end)?.isASCIILetter != true {
                text += "e" + String(chars[(index + 1) ..< end])
                index = end
            }
        }
        if text.hasPrefix(".") { text = "0" + text }
        if text.hasSuffix(".") { text.removeLast() }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw Failure.unexpected(chars[start])
        }
        return (.number(value, text: text, radix: false), index)
    }

    private static func isThousandsGroup(_ chars: [Character], at comma: Int) -> Bool {
        for offset in 1 ... 3 where chars.at(comma + offset)?.isASCIIDigit != true { return false }
        return chars.at(comma + 4)?.isASCIIDigit != true
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
    var isASCIIAlphanumeric: Bool { isASCIIDigit || isASCIILetter }
}

private extension Array {
    func at(_ index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
