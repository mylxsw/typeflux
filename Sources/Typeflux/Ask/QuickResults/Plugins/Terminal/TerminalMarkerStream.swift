import Foundation

/// A PTY read may end anywhere, including between ESC and the string terminator.
struct TerminalMarkerStream {
    enum Event: Equatable {
        case bytes([UInt8]), prompt, input, output, complete(Int32), directory(String), path(String)
    }

    private var pending: [UInt8] = []

    mutating func read(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        var plain: [UInt8] = []
        for byte in bytes {
            if pending.isEmpty {
                if byte == 27 {
                    pending.append(byte)
                } else {
                    plain.append(byte)
                }
            } else if pending.count == 1, byte != 93 {
                plain.append(27)
                pending.removeAll(keepingCapacity: true)
                if byte == 27 {
                    pending.append(byte)
                } else {
                    plain.append(byte)
                }
            } else {
                pending.append(byte)
                let terminator = byte == 7 ? 1 : pending.suffix(2) == [27, 92] ? 2 : 0
                if terminator > 0 {
                    let body = String(decoding: pending.dropFirst(2).dropLast(terminator), as: UTF8.self)
                    if let marker = Self.marker(body) {
                        if !plain.isEmpty {
                            events.append(.bytes(plain))
                            plain.removeAll(keepingCapacity: true)
                        }
                        events.append(marker)
                    } else {
                        plain.append(contentsOf: pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count >= 8192 {
                    plain.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        if !plain.isEmpty {
            events.append(.bytes(plain))
        }
        return events
    }

    private static func marker(_ body: String) -> Event? {
        switch body {
        case "133;A": return .prompt
        case "133;B": return .input
        case "133;C": return .output
        default:
            if body.hasPrefix("133;D;"), let code = Int32(body.dropFirst(6)) {
                return .complete(code)
            }
            let pathMarker = "133;P;TypefluxPath="
            if body.hasPrefix(pathMarker), let path = body.dropFirst(pathMarker.count).removingPercentEncoding {
                return .path(path)
            }
            if body.hasPrefix("7;file://"), let url = URL(string: String(body.dropFirst(2))),
               url.path.hasPrefix("/") {
                return .directory(url.path)
            }
            return nil
        }
    }
}
