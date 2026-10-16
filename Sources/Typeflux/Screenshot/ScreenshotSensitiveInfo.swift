import CoreGraphics
import Foundation
import TypefluxMediaProtocol

/// Something on a screenshot that should probably be covered before it is shared.
struct ScreenshotSensitiveFinding: Equatable, Identifiable {
    typealias Kind = MediaSensitiveText.Kind

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
    typealias Match = MediaSensitiveText.Match

    static func findings(in text: RecognizedText) -> [ScreenshotSensitiveFinding] {
        text.lines.flatMap { line in
            let string = line.text as NSString
            return (line.sensitiveMatches ?? matches(in: line.text)).map { match in
                ScreenshotSensitiveFinding(kind: match.kind, text: string.substring(with: match.range),
                                           boundingBox: box(of: match.range, in: line))
            }
        }
    }

    static func matches(in string: String) -> [Match] { MediaSensitiveText.matches(in: string) }
    static func isFormattedPhone(_ text: String) -> Bool { MediaSensitiveText.isFormattedPhone(text) }
    static func digits(of text: String) -> String { MediaSensitiveText.digits(of: text) }
    static func isLuhnValid(_ text: String) -> Bool { MediaSensitiveText.isLuhnValid(text) }
    static func isResidentID(_ text: String) -> Bool { MediaSensitiveText.isResidentID(text) }
    static func isCreditCode(_ text: String) -> Bool { MediaSensitiveText.isCreditCode(text) }

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

extension MediaSensitiveText.Kind {
    var title: String { L("screenshot.sensitive.kind.\(rawValue)") }
}
