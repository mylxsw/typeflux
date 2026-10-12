import Foundation

enum AskFilePreviewText {
    /// Permit an incomplete final UTF-8 scalar only at the byte cap, never invalid bytes within the file.
    static func decode(_ data: Data, hasMore: Bool) -> (text: String, truncated: Bool)? {
        guard !data.contains(where: { $0 == 0 || ($0 < 32 && ![9, 10, 13].contains($0)) }) else { return nil }
        var text = String(data: data, encoding: .utf8)
        if text == nil, hasMore {
            for removed in 1 ... min(3, data.count) {
                let suffix = Array(data.suffix(removed))
                guard let lead = suffix.first else { continue }
                let expected = (0xC2 ... 0xDF).contains(lead) ? 2 : (0xE0 ... 0xEF).contains(lead) ? 3 : (0xF0 ... 0xF4)
                    .contains(lead) ? 4 : 0
                guard expected > removed,
                      suffix.dropFirst().allSatisfy({ (0x80 ... 0xBF).contains($0) }) else { continue }
                if suffix.count > 1 {
                    let second = suffix[1]
                    // Reject overlong encodings, surrogate scalars and values above U+10FFFF,
                    // even when the byte cap cuts off the remainder of that scalar.
                    if (lead == 0xE0 && second < 0xA0) || (lead == 0xED && second >= 0xA0)
                        || (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second > 0x8F) {
                        continue
                    }
                }
                if let value = String(data: data.dropLast(removed), encoding: .utf8) {
                    text = value; break
                }
            }
        }
        guard let text else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.prefix(200).joined(separator: "\n"), hasMore || lines.count > 200)
    }

    /// Handles quoted separators, escaped quotes and multiline cells within the bounded text sample.
    static func table(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        let chars = Array(text)
        var index = 0
        while index < chars.count, rows.count < 30 {
            let char = chars[index]
            if char == "\"" {
                if quoted, index + 1 < chars.count, chars[index + 1] == "\"" {
                    cell.append(char); index += 1
                } else {
                    quoted.toggle()
                }
            } else if char == separator, !quoted {
                if row.count < 30 {
                    row.append(cell)
                }; cell = ""
            } else if char == "\n", !quoted {
                if row.count < 30 {
                    row.append(cell)
                }; rows.append(row); row = []; cell = ""
            } else {
                cell.append(char)
            }
            index += 1
        }
        if rows.count < 30, !cell.isEmpty || !row.isEmpty {
            if row.count < 30 {
                row.append(cell)
            }; rows.append(row)
        }
        return rows
    }
}
