import Foundation

public enum SSEFrameError: Error { case invalidResponse }

/// Bounded SSE decoder. Consume bytes rather than AsyncBytes.lines, which omits
/// empty lines and therefore loses frame boundaries. Partial UTF-8 stays buffered.
public struct SSEFrame: Sendable {
    public let limit: Int
    public private(set) var event = "message"
    public private(set) var data = ""
    private var lineBytes = Data()

    public init(limit: Int = 2_000_000) { self.limit = max(1, limit) }

    public mutating func push(_ byte: UInt8) throws -> (String, String)? {
        if byte == 10 {
            if lineBytes.last == 13 { lineBytes.removeLast() }
            guard let line = String(data: lineBytes, encoding: .utf8) else { throw SSEFrameError.invalidResponse }
            lineBytes.removeAll(keepingCapacity: true)
            return try append(line)
        }
        guard lineBytes.count < limit else { throw SSEFrameError.invalidResponse }
        lineBytes.append(byte)
        return nil
    }

    public mutating func append(_ line: String) throws -> (String, String)? {
        guard line.utf8.count <= limit else { throw SSEFrameError.invalidResponse }
        if line.isEmpty {
            defer { event = "message"; data = "" }
            return data.isEmpty ? nil : (event, String(data.dropLast()))
        }
        if line.hasPrefix("event:") {
            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            guard data.utf8.count + value.utf8.count + 1 <= limit else { throw SSEFrameError.invalidResponse }
            data += value + "\n"
        }
        return nil
    }
}
