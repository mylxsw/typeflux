import CoreGraphics
import Foundation

/// Something on a screenshot that should probably be covered before it is shared.
struct ScreenshotSensitiveFinding: Equatable, Identifiable {
    enum Kind: String, CaseIterable, Equatable {
        case phone, email, bankCard, idCard, creditCode, address

        var title: String { L("screenshot.sensitive.kind.\(rawValue)") }
    }

    var id = UUID()
    var kind: Kind
    var text: String
    /// Where it is, normalized to the image (0...1) with the origin at the top-left corner.
    var boundingBox: CGRect

    /// The text with its middle hidden, for the list: "138•••••8000". Spaces are left out.
    var maskedText: String { Self.mask(text.filter { !$0.isWhitespace }) }

    /// Where it is in an image of `scale` pixels per point, in that image's points.
    func rect(imageSize: CGSize, scale: CGFloat) -> CGRect {
        let scale = max(scale, 0.01)
        return CGRect(x: boundingBox.minX * imageSize.width / scale, y: boundingBox.minY * imageSize.height / scale,
                      width: boundingBox.width * imageSize.width / scale,
                      height: boundingBox.height * imageSize.height / scale)
    }

    static func mask(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count > 4 else { return String(repeating: "•", count: characters.count) }
        let shown = max(1, characters.count / 4)
        return String(characters.prefix(shown)) + String(repeating: "•", count: characters.count - shown * 2)
            + String(characters.suffix(shown))
    }
}

/// Finds phone numbers, email addresses, bank cards (Luhn-checked), 18-digit resident
/// ID numbers (check digit verified), unified social credit codes (check character verified)
/// and addresses in recognized text. Everything runs on this Mac; the result is only advice.
enum ScreenshotSensitiveInfoDetector {
    /// A match in one string, before it is placed on the image.
    struct Match: Equatable {
        var kind: ScreenshotSensitiveFinding.Kind
        var range: NSRange
    }

    static func findings(in text: RecognizedText) -> [ScreenshotSensitiveFinding] {
        text.lines.flatMap { line in
            let string = line.text as NSString
            return matches(in: line.text).map { match in
                ScreenshotSensitiveFinding(kind: match.kind, text: string.substring(with: match.range),
                                           boundingBox: box(of: match.range, in: line))
            }
        }
    }

    /// Every match in `string`, left to right. Where two overlap the more specific rule wins:
    /// ID numbers, credit codes and cards before phone numbers, rules before the system detector.
    static func matches(in string: String) -> [Match] {
        var found: [Match] = []
        func add(_ kind: ScreenshotSensitiveFinding.Kind, _ range: NSRange) {
            guard range.length > 0,
                  !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            found.append(Match(kind: kind, range: range))
        }
        let nsString = string as NSString
        for (kind, regex, isValid) in rules {
            for result in regex.matches(in: string, range: NSRange(location: 0, length: nsString.length))
                where isValid(nsString.substring(with: result.range)) {
                add(kind, result.range)
            }
        }
        for result in dataDetector?.matches(in: string, range: NSRange(location: 0, length: nsString.length)) ?? [] {
            switch result.resultType {
            case .phoneNumber:
                if isFormattedPhone(nsString.substring(with: result.range)) { add(.phone, result.range) }
            case .address:
                add(.address, result.range)
            default:
                break
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    // MARK: Rules

    private typealias Rule = (ScreenshotSensitiveFinding.Kind, NSRegularExpression, (String) -> Bool)

    private static let rules: [Rule] = [
        (.idCard, regex(#"(?<![0-9A-Za-z])\d{17}[\dXx](?![0-9A-Za-z])"#), isResidentID),
        (.creditCode, regex(#"(?<![0-9A-Za-z])[0-9A-HJ-NP-RTUW-Y]{2}\d{6}[0-9A-HJ-NP-RTUW-Y]{10}(?![0-9A-Za-z])"#),
         isCreditCode),
        (.bankCard, regex(#"(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d-])"#), { isLuhnValid(digits(of: $0)) }),
        (.phone, regex(#"(?<![\d+])(?:\+?86[ -]?)?1[3-9]\d(?:[ -]?\d{4}){2}(?!\d)"#), { _ in true }),
        (.email, regex(#"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#),
         { _ in true })
    ]

    private static let dataDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
    )

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by the tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// What the system detector calls a phone number counts when it is written like one: 7 to 15
    /// digits with a `+`, brackets, spaces or dashes. Bare runs of digits (order numbers, IDs
    /// that failed their check) are left to the rules, which know which of them are phones.
    static func isFormattedPhone(_ text: String) -> Bool {
        let count = digits(of: text).count
        return (7 ... 15).contains(count) && text.contains { "+() -".contains($0) }
    }

    static func digits(of text: String) -> String {
        text.filter(\.isASCIIDigit)
    }

    /// The Luhn check bank cards carry in their last digit; 13 to 19 digits.
    static func isLuhnValid(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, (13 ... 19).contains(values.count),
              Set(values).count > 1 else { return false }
        let sum = values.reversed().enumerated().reduce(0) { total, item in
            let (index, value) = item
            guard index % 2 == 1 else { return total + value }
            let doubled = value * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    /// An 18-character resident ID: a plausible birth date and the ISO 7064 check character.
    static func isResidentID(_ text: String) -> Bool {
        let characters = Array(text.uppercased())
        guard characters.count == 18 else { return false }
        let values = characters.prefix(17).compactMap(\.wholeNumberValue)
        guard values.count == 17,
              let year = Int(String(characters[6 ..< 10])), (1900 ... 2100).contains(year),
              let month = Int(String(characters[10 ..< 12])), (1 ... 12).contains(month),
              let day = Int(String(characters[12 ..< 14])), (1 ... 31).contains(day) else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let sum = zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 }
        let check = Array("10X98765432")[sum % 11]
        return characters[17] == check
    }

    /// An 18-character unified social credit code with its GB 32100 check character.
    static func isCreditCode(_ text: String) -> Bool {
        let alphabet = Array("0123456789ABCDEFGHJKLMNPQRTUWXY")
        let characters = Array(text.uppercased())
        guard characters.count == 18 else { return false }
        let values = characters.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 18 else { return false }
        let weights = [1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28]
        let sum = zip(values.prefix(17), weights).reduce(0) { $0 + $1.0 * $1.1 }
        return values[17] == (31 - sum % 31) % 31
    }

    // MARK: Placement

    /// Where a range of a line's text is: the recognizer's exact bounds when it has them,
    /// otherwise an estimate from the range's share of the line.
    static func box(of range: NSRange, in line: RecognizedText.Line) -> CGRect {
        if let exact = line.locate?(range), exact.width > 0, exact.height > 0 {
            // Exact bounds hug the glyphs; a little room keeps their edges covered.
            let pad = exact.height * 0.15
            return exact.insetBy(dx: -pad, dy: 0).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return estimatedBox(of: range, in: line)
    }

    /// The range's share of the line, wide (CJK) characters counting double, widened by one
    /// character on each side so the estimate errs toward covering too much.
    static func estimatedBox(of range: NSRange, in line: RecognizedText.Line) -> CGRect {
        let units = Array(line.text.utf16)
        func width(_ slice: ArraySlice<UInt16>) -> CGFloat {
            String(utf16CodeUnits: Array(slice), count: slice.count).reduce(0) { $0 + (isWide($1) ? 2 : 1) }
        }
        let lower = max(0, min(range.location, units.count))
        let upper = max(lower, min(range.location + range.length, units.count))
        let total = width(units[...])
        guard total > 0 else { return line.boundingBox }
        let unit = line.boundingBox.width / total
        let start = line.boundingBox.minX + width(units[..<lower]) * unit - unit
        let end = line.boundingBox.minX + width(units[..<upper]) * unit + unit
        let minX = max(line.boundingBox.minX, start), maxX = min(line.boundingBox.maxX, end)
        return CGRect(x: minX, y: line.boundingBox.minY, width: max(maxX - minX, 0), height: line.boundingBox.height)
    }

    static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF, 0xFE30 ... 0xFE4F,
             0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6, 0x20000 ... 0x3FFFD:
            return true
        default:
            return false
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
