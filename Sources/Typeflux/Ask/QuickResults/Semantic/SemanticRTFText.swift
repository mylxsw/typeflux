import CoreFoundation
import Darwin
import Foundation

/// Offline RTF body extraction. No rich-text importer, object decoder or resource loader is used.
enum SemanticRTFText {
    static let recipe = "rtf-body-unicode-cp1252-936-950-stream-v1"

    static func read(descriptor: Int32, size: Int64, cursor: SemanticContentCursor) throws -> AskFileReadResponse {
        guard cursor.page == 0, cursor.offset >= 0 else { throw SemanticDocumentError(EINVAL) }
        let body = SemanticRTFBody(offset: cursor.offset)
        try body.parse(SemanticRTFInput(descriptor: descriptor, size: size))
        guard body.seen >= cursor.offset else { throw SemanticDocumentError(EINVAL) }
        guard let part = AskFileWorkerCommand.contentSlice(body.bytes, offset: 0) else { throw SemanticDocumentError() }
        let next = body.stopped ? SemanticContentCursor(offset: cursor.offset + Int64(part.consumed)) : nil
        return .init(pages: [.init(text: part.text, offset: cursor.offset, segmentKind: "rtf-body")], nextCursor: next)
    }
}

private final class SemanticRTFInput {
    private let descriptor: Int32
    private let size: Int64
    private var position: Int64 = 0
    private var buffer = [UInt8](repeating: 0, count: 8192)
    private var index = 0
    private var count = 0

    init(descriptor: Int32, size: Int64) { self.descriptor = descriptor; self.size = size }

    func next() throws -> UInt8? {
        if index == count {
            if position == size { return nil }
            repeat {
                count = buffer.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress, Int(min(Int64($0.count), size - position)), off_t(position))
                }
            } while count < 0 && errno == EINTR
            guard count > 0 else { throw SemanticDocumentError(count < 0 ? errno : EAGAIN) }
            index = 0
        }
        defer { index += 1; position += 1 }
        return buffer[index]
    }

    func unread() { index -= 1; position -= 1 }

    func skip(_ amount: Int) throws {
        guard amount >= 0, Int64(amount) <= size - position else { throw SemanticDocumentError() }
        position += Int64(amount); index = 0; count = 0
    }
}

private final class SemanticRTFBody {
    private struct State {
        var skipped = false
        var hidden = false
        var fontTable = false
        var font: Int?
        var codePage = 1252
        var unicodeCount = 1
    }
    private var state = State()
    private var stack: [State] = []
    private var fonts: [Int: Int] = [:]
    private var defaultFont: Int?
    private var fallback = 0
    private var high: UInt16?
    private var lead: UInt8?
    private var rawLead = false
    private let offset: Int64
    var bytes = Data()
    var seen: Int64 = 0
    var stopped = false
    private let destinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "filetbl", "datastore",
        "header", "headerl", "headerr", "headerf", "footer", "footerl", "footerr", "footerf",
        "footnote", "annotation", "fldinst", "listtable", "listoverridetable", "listtext", "pntext",
        "shp", "nonshppict", "xmlnstbl", "themedata", "colorschememapping"
    ]

    init(offset: Int64) { self.offset = offset }

    // swiftlint:disable:next cyclomatic_complexity
    func parse(_ input: SemanticRTFInput) throws {
        // Require an actual RTF header; raw text with a renamed extension is not accepted.
        for byte in Array("{\\rtf1".utf8) {
            guard try input.next() == byte else { throw SemanticDocumentError() }
        }
        guard let delimiter = try input.next(), !isLetter(delimiter), !(48...57).contains(delimiter)
        else { throw SemanticDocumentError() }
        if delimiter != 32 { input.unread() }
        stack.append(state)
        while !stopped, let byte = try input.next() {
            // Raw DBCS trails may equal an RTF delimiter; escaped hex runs remain tokenized.
            if rawLead { rawLead = false; try character(byte); continue }
            if stack.isEmpty {
                guard [9, 10, 13, 32].contains(byte) else { throw SemanticDocumentError() }
                continue
            }
            switch byte {
            case 123:
                guard lead == nil else { throw SemanticDocumentError() }
                // Syntax complexity bound, independent of file length or number of batches.
                guard stack.count < 256 else { throw SemanticDocumentError(ENOTSUP) }
                stack.append(state); fallback = 0
            case 125:
                guard lead == nil, let parent = stack.popLast() else { throw SemanticDocumentError() }
                state = parent; fallback = 0
            case 92: try control(input)
            case 10, 13: break
            default:
                try character(byte)
                rawLead = lead != nil
            }
        }
        guard stopped || (stack.isEmpty && high == nil && lead == nil) else { throw SemanticDocumentError() }
    }

    private func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }

    // swiftlint:disable:next cyclomatic_complexity
    private func control(_ input: SemanticRTFInput) throws {
        guard let first = try input.next() else { throw SemanticDocumentError() }
        if first == 39 {
            guard let firstHex = try input.next(), let secondHex = try input.next(),
                  let value = UInt8(String(bytes: [firstHex, secondHex], encoding: .ascii) ?? "", radix: 16)
            else { throw SemanticDocumentError() }
            try character(value); return
        }
        if !isLetter(first) {
            if first == 42 { state.skipped = true; return }
            if [92, 123, 125].contains(first) { try character(first); return }
            if fallback > 0 { fallback -= 1; return }
            let symbols: [UInt8: String] = [126: "\u{a0}", 45: "\u{ad}", 95: "\u{2011}"]
            if let text = symbols[first], !state.skipped, !state.hidden { try emit(text) }
            return
        }
        var word = [first]
        var byte = try input.next()
        while let current = byte, isLetter(current) {
            guard word.count < 32 else { throw SemanticDocumentError() }
            word.append(current); byte = try input.next()
        }
        var sign = 1, number = 0, digits = 0
        if byte == 45 { sign = -1; byte = try input.next() }
        while let current = byte, (48...57).contains(current) {
            guard digits < 10, number <= (Int(Int32.max) - Int(current - 48)) / 10
            else { throw SemanticDocumentError() }
            number = number * 10 + Int(current - 48); digits += 1; byte = try input.next()
        }
        if let byte, byte != 32 { input.unread() }
        try command(String(bytes: word, encoding: .ascii)!, value: digits > 0 ? sign * number : nil, input: input)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func command(_ word: String, value: Int?, input: SemanticRTFInput) throws {
        if word == "bin" {
            guard let value else { throw SemanticDocumentError() }
            try input.skip(value)
            if fallback > 0 { fallback -= 1 }
            return
        }
        if fallback > 0 { fallback -= 1; return }
        guard lead == nil else { throw SemanticDocumentError() }
        if word == "fonttbl" { state.fontTable = true }
        if destinations.contains(word) { state.skipped = true }
        if word == "f", let value { state.font = value }
        if state.fontTable, ["fcharset", "cpg"].contains(word), let value, let font = state.font {
            guard fonts.count < 1024 || fonts[font] != nil else { throw SemanticDocumentError(ENOTSUP) }
            let charsets = [0: 0, 1: 0, 134: 936, 136: 950]
            fonts[font] = word == "cpg" ? value : charsets[value] ?? -1
        }
        guard !state.skipped else { return }
        switch word {
        case "ansicpg":
            guard let value, [1252, 936, 950].contains(value) else { throw SemanticDocumentError(ENOTSUP) }
            state.codePage = value
        case "mac", "pc", "pca", "upr": throw SemanticDocumentError(ENOTSUP)
        case "deff": defaultFont = value; state.font = value
        case "plain": state.font = defaultFont; state.hidden = false
        case "v": state.hidden = value != 0
        case "uc":
            guard let value, (0...32767).contains(value) else { throw SemanticDocumentError() }
            state.unicodeCount = value
        case "u":
            guard let value, (-32768...65535).contains(value), lead == nil else { throw SemanticDocumentError() }
            if !state.hidden { try unicode(UInt16(truncatingIfNeeded: value)) }
            fallback = state.unicodeCount
        default:
            let text = ["par": "\n", "line": "\n", "tab": "\t", "cell": "\t", "row": "\n",
                        "emdash": "—", "endash": "–", "bullet": "•", "lquote": "‘", "rquote": "’",
                        "ldblquote": "“", "rdblquote": "”"]
            if let text = text[word], !state.hidden { try emit(text) }
        }
    }

    private func character(_ byte: UInt8) throws {
        if fallback > 0 { fallback -= 1; return }
        guard !state.skipped, !state.hidden else { return }
        guard byte >= 32 || byte == 9 else { throw SemanticDocumentError() }
        let selected = state.font.flatMap { fonts[$0] } ?? 0
        let page = selected == 0 ? state.codePage : selected
        var data: [UInt8]
        if let lead { data = [lead, byte]; self.lead = nil } else {
            if byte < 128 { try emit(String(UnicodeScalar(byte))); return }
            guard [1252, 936, 950].contains(page) else { throw SemanticDocumentError(ENOTSUP) }
            if page != 1252, (0x81...0xFE).contains(byte) { lead = byte; return }
            data = [byte]
        }
        let encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(page))
        guard encoding != kCFStringEncodingInvalidId,
              let text = String(data: Data(data), encoding:
                .init(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
        else { throw SemanticDocumentError() }
        try emit(text)
    }

    private func unicode(_ unit: UInt16) throws {
        if (0xD800...0xDBFF).contains(unit) {
            guard high == nil else { throw SemanticDocumentError() }
            high = unit
        } else if (0xDC00...0xDFFF).contains(unit) {
            guard let high else { throw SemanticDocumentError() }
            self.high = nil
            try emit(String(UnicodeScalar(0x10000 + (UInt32(high) - 0xD800) * 1024 + UInt32(unit) - 0xDC00)!))
        } else { try emit(String(UnicodeScalar(unit)!)) }
    }

    private func emit(_ text: String) throws {
        guard high == nil, lead == nil else { throw SemanticDocumentError() }
        for scalar in text.unicodeScalars {
            guard scalar.value >= 32 || [9, 10, 13].contains(scalar.value) else { throw SemanticDocumentError() }
            let count = Int64(scalar.utf8.count)
            if seen >= offset { bytes.append(contentsOf: scalar.utf8) } else if seen + count > offset {
                throw SemanticDocumentError(EINVAL)
            }
            seen += count
            if bytes.count >= SemanticFilePolicy.contentBatchBytes + 4 { stopped = true; return }
        }
    }
}
