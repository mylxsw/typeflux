import Foundation

/// Shared bounded recognition rules; localization and presentation stay in the host.
public enum MediaSensitiveText {
    public enum Kind: String, Codable, CaseIterable, Sendable { case phone, email, bankCard, idCard, creditCode, address }
    public struct Match: Equatable, Sendable {
        public var kind: Kind
        public var range: NSRange
        public init(kind: Kind, range: NSRange) { self.kind = kind; self.range = range }
    }
    /// Every match in `string`, left to right. Where two overlap the more specific rule wins:
    /// ID numbers, credit codes and cards before phone numbers, rules before the system detector.
    public static func matches(in string: String) -> [Match] {
        var found: [Match] = []
        func add(_ kind: Kind, _ range: NSRange) {
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

    private typealias Rule = (Kind, NSRegularExpression, (String) -> Bool)

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
    public static func isFormattedPhone(_ text: String) -> Bool {
        let count = digits(of: text).count
        return (7 ... 15).contains(count) && text.contains { "+() -".contains($0) }
    }

    public static func digits(of text: String) -> String {
        text.filter(\.isASCIIDigit)
    }

    /// The Luhn check bank cards carry in their last digit; 13 to 19 digits.
    public static func isLuhnValid(_ digits: String) -> Bool {
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
    public static func isResidentID(_ text: String) -> Bool {
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
    public static func isCreditCode(_ text: String) -> Bool {
        let alphabet = Array("0123456789ABCDEFGHJKLMNPQRTUWXY")
        let characters = Array(text.uppercased())
        guard characters.count == 18 else { return false }
        let values = characters.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 18 else { return false }
        let weights = [1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28]
        let sum = zip(values.prefix(17), weights).reduce(0) { $0 + $1.0 * $1.1 }
        return values[17] == (31 - sum % 31) % 31
    }

}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
