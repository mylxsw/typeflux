import Foundation

/// Incremental SSE framing. Decode UTF-8 only after a complete line has arrived,
/// so a network chunk can end anywhere, including inside a Unicode scalar.
struct MCPSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var afterCR = false
    private var firstLine = true
    let maximumEventBytes: Int

    init(maximumEventBytes: Int = 8 * 1024 * 1024) {
        self.maximumEventBytes = maximumEventBytes
    }

    /// Returns false from receive to stop parsing immediately after the result.
    mutating func append(_ chunk: Data, receive: (Data) throws -> Bool) throws {
        for byte in chunk {
            if afterCR {
                afterCR = false
                if byte == 10 {
                    continue
                }
            }
            if byte == 10 || byte == 13 {
                afterCR = byte == 13
                if let event = try consumeLine(), try !receive(event) {
                    return
                }
            } else {
                guard line.count + eventBytes < maximumEventBytes else {
                    throw MCPClientError.invalidResponse("SSE event exceeds the size limit")
                }
                line.append(byte)
            }
        }
    }

    /// An unterminated frame at EOF is deliberately discarded, per SSE framing.
    private mutating func consumeLine() throws -> Data? {
        guard var text = String(data: line, encoding: .utf8) else {
            throw MCPClientError.invalidResponse("SSE line is not valid UTF-8")
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") {
                text.removeFirst()
            }
        }
        if text.isEmpty {
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            return payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Data(payload.utf8)
        }
        if text.hasPrefix(":") {
            return nil
        }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "data" else { return nil }
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") {
            value.removeFirst()
        }
        eventBytes += value.utf8.count + 1
        dataLines.append(value)
        return nil
    }
}
