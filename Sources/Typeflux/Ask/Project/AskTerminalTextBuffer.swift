import Foundation

/// Byte cursors and UTF-8 boundaries are independent. Retain up to three pending
/// bytes across pages and expose every gap instead of silently joining fragments.
struct AskTerminalTextBuffer {
    private(set) var cursor: Int64 = 0
    private(set) var text = ""
    private(set) var lostBytes: Int64 = 0
    private(set) var truncated = false
    private var pending = Data()

    mutating func append(_ page: AskTerminalOutput, final: Bool) throws {
        guard page.offset >= 0, page.nextCursor == page.offset + Int64(page.data.count), page.lostBytes >= 0 else {
            throw AskProjectRuntimeError.invalidCursor
        }
        if page.nextCursor < cursor || (page.nextCursor == cursor && !page.data.isEmpty) {
            return
        }
        guard page.offset == cursor + page.lostBytes else { throw AskProjectRuntimeError.invalidCursor }
        if page.lostBytes > 0 {
            pending = Data(); lostBytes += page.lostBytes
            text += "\n[Lost \(page.lostBytes) output bytes]\n"
        }
        pending.append(page.data); cursor = page.nextCursor
        var length = pending.count
        if !final, !pending.isEmpty {
            let bytes = Array(pending.suffix(4))
            if let index = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
                let first = bytes[index]
                let expected = (0xC2 ... 0xDF).contains(first) ? 2 :
                    ((0xE0 ... 0xEF).contains(first) ? 3 : ((0xF0 ... 0xF4).contains(first) ? 4 : 1))
                let present = bytes.count - index
                if expected > present {
                    length -= present
                }
            }
        }
        // Invalid process bytes are displayed with replacement characters.
        // swiftlint:disable:next optional_data_string_conversion
        text += String(decoding: pending.prefix(length), as: UTF8.self)
        pending = Data(pending.dropFirst(length))
        if text.utf8.count > 65536 {
            text = String(text.suffix(16384)); truncated = true
        }
    }
}
