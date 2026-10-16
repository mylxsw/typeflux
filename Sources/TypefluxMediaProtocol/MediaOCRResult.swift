import Foundation

/// Clipboard file-to-text only. No Vision objects or approximate glyph geometry cross IPC.
public struct MediaOCRResult: Codable, Sendable {
    public static let inputBytes = 10 * 1024 * 1024
    public static let responseBytes = 2 * 1024 * 1024
    public static let maximumLines = 1024
    public static let textBytes = 256 * 1024
    public var lines: [String]
    public init(lines: [String]) { self.lines = lines }
    public func validate() throws {
        guard lines.count <= Self.maximumLines else { throw MediaFailure.tooLarge }
        var total = 0
        for line in lines {
            guard line.utf8.count <= 16 * 1024, !line.contains("\0") else { throw MediaFailure.tooLarge }
            total += line.utf8.count + 1
            guard total <= Self.textBytes else { throw MediaFailure.tooLarge }
        }
    }
    public var text: String? {
        let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
