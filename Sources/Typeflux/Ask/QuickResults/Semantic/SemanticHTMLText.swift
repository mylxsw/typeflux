import Darwin
import Foundation

/// UTF-8 HTML body text, replayed to a logical cursor with bounded source/output buffers.
/// Tags are scanned as data; scripts, styles, links and embedded objects are never imported.
enum SemanticHTMLText {
    static let recipe = "html-utf8-offline-body-stream-v1"

    static func read(descriptor: Int32, size: Int64, cursor: SemanticContentCursor) throws -> AskFileReadResponse {
        guard cursor.page == 0, cursor.offset >= 0 else { throw SemanticDocumentError(EINVAL) }
        let input = SemanticHTMLInput(descriptor: descriptor, size: size)
        let body = SemanticHTMLBody(offset: cursor.offset)
        try body.parse(input)
        guard body.seen >= cursor.offset else { throw SemanticDocumentError(EINVAL) }
        guard let part = AskFileWorkerCommand.contentSlice(body.bytes, offset: 0)
        else { throw SemanticDocumentError() }
        let next = body.stopped ? SemanticContentCursor(offset: cursor.offset + Int64(part.consumed)) : nil
        return .init(pages: [.init(text: part.text, offset: cursor.offset, segmentKind: "html-body")], nextCursor: next)
    }
}

private final class SemanticHTMLInput {
    private let descriptor: Int32
    private let size: Int64
    private var position: Int64 = 0
    private var buffer = [UInt8](repeating: 0, count: 8192)
    private var index = 0
    private var count = 0
    private var pending: UInt8?

    init(descriptor: Int32, size: Int64) { self.descriptor = descriptor; self.size = size }

    func unread(_ byte: UInt8) { pending = byte }

    func next() throws -> UInt8? {
        if let pending { self.pending = nil; return pending }
        if index == count {
            if position == size { return nil }
            repeat {
                count = buffer.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress, min($0.count, Int(size - position)), off_t(position))
                }
            } while count < 0 && errno == EINTR
            guard count > 0 else { throw SemanticDocumentError(count < 0 ? errno : EAGAIN) }
            index = 0
            if position == 0 {
                if buffer[0] == 0xFF || buffer[0] == 0xFE { throw SemanticDocumentError(ENOTSUP) }
                if count >= 3, Array(buffer.prefix(3)) == [0xEF, 0xBB, 0xBF] { index = 3 }
            }
            position += Int64(count)
            if index == count { return try next() }
        }
        defer { index += 1 }
        return buffer[index]
    }
}

private final class SemanticHTMLBody {
    private let offset: Int64
    private var hidden: String?
    private var hiddenDepth = 0
    private var separator: UInt8?
    var bytes = Data()
    var seen: Int64 = 0
    var stopped = false
    private let blocks: Set<String> = ["br", "p", "div", "section", "article", "li", "tr", "table", "blockquote", "pre",
                                       "h1", "h2", "h3", "h4", "h5", "h6"]

    init(offset: Int64) { self.offset = offset }

    // swiftlint:disable:next cyclomatic_complexity
    func parse(_ input: SemanticHTMLInput) throws {
        while !stopped, let byte = try input.next() {
            if byte == 60 {
                guard let first = try input.next() else {
                    if hidden == nil { try emit([60]) }
                    break
                }
                input.unread(first)
                if !(65...90).contains(first), !(97...122).contains(first), ![47, 33, 63].contains(first) {
                    if hidden == nil { try emit([60]) }
                    continue
                }
                let tag = try markup(input)
                if ["script", "style"].contains(tag.name), !tag.closing {
                    try skipRaw(input, name: tag.name)
                    separate(32)
                } else if let hidden {
                    if tag.name == hidden { hiddenDepth += tag.closing ? -1 : 1 }
                    if hiddenDepth == 0 { self.hidden = nil; separate(32) }
                } else if !tag.closing, AskOfflineHTML.ignoredTags.contains(tag.name) {
                    hidden = tag.name; hiddenDepth = 1; separate(32)
                } else {
                    separate(blocks.contains(tag.name) ? 10 : 32)
                    if !tag.closing, tag.name == "li" { try emit(Array("- ".utf8)) }
                    if !tag.closing, tag.name.count == 2, tag.name.first == "h", blocks.contains(tag.name) {
                        try emit(Array("# ".utf8))
                    }
                }
            } else if hidden == nil {
                if byte == 38 { try entity(input) } else { try emit([byte]) }
            }
        }
    }

    // Only retain a short ASCII name; arbitrarily long attributes/comments consume no growing allocation.
    // swiftlint:disable:next cyclomatic_complexity
    private func markup(_ input: SemanticHTMLInput) throws -> (name: String, closing: Bool) {
        var prefix: [UInt8] = [], name: [UInt8] = [], quote: UInt8?, readingName = true, closing = false
        while let byte = try input.next() {
            if prefix.count < 3 {
                prefix.append(byte)
                if prefix == [33, 45, 45] {
                    var dashes = 0
                    while let byte = try input.next() {
                        if byte == 62, dashes >= 2 { break }
                        dashes = byte == 45 ? min(2, dashes + 1) : 0
                    }
                    return ("", false)
                }
            }
            if let current = quote { if byte == current { quote = nil }; continue }
            if byte == 62 { return (String(bytes: name, encoding: .ascii) ?? "", closing) }
            if byte == 34 || byte == 39 { quote = byte; readingName = false; continue }
            if readingName {
                if byte == 47, name.isEmpty { closing = true; continue }
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) {
                    if name.count < 32 { name.append(byte >= 65 && byte <= 90 ? byte + 32 : byte) }
                } else { readingName = false }
            }
        }
        // An unfinished tag is not body text. EOF is still a complete source read.
        return ("", false)
    }

    /// Raw text may contain '<' or '>'; only the matching end tag terminates it.
    private func skipRaw(_ input: SemanticHTMLInput, name: String) throws {
        let ending = Array(("</" + name).utf8)
        var matched = 0
        while let byte = try input.next() {
            let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
            if matched == ending.count {
                if byte == 62 { return }
                if [9, 10, 13, 32, 47].contains(byte) { continue }
                matched = 0
            }
            if lower == ending[matched] { matched += 1 } else { matched = lower == 60 ? 1 : 0 }
        }
    }

    private func entity(_ input: SemanticHTMLInput) throws {
        var token: [UInt8] = [38]
        while let byte = try input.next() {
            if byte == 59 {
                token.append(byte)
                guard let text = String(bytes: token, encoding: .utf8) else { throw SemanticDocumentError() }
                try emit(Array(AskOfflineHTML.decodeEntities(text).utf8))
                return
            }
            // Do not consume markup or a second entity as part of a malformed reference.
            if byte == 60 || byte == 38 {
                try emit(token)
                input.unread(byte)
                return
            }
            token.append(byte)
            if token.count >= 32 || [9, 10, 13, 32].contains(byte) { try emit(token); return }
        }
        try emit(token)
    }

    private func separate(_ byte: UInt8) {
        if separator != 10 { separator = byte }
    }

    private func emit(_ input: [UInt8]) throws {
        for byte in input where !stopped {
            if [9, 10, 13, 32].contains(byte) { separate(byte == 10 ? 10 : 32); continue }
            guard byte >= 32 else { throw SemanticDocumentError() }
            if let separator, seen > 0 { try append(separator) }
            separator = nil
            try append(byte)
        }
    }

    private func append(_ byte: UInt8) throws {
        guard !stopped else { return }
        if seen >= offset {
            if seen == offset, byte & 0xC0 == 0x80 { throw SemanticDocumentError(EINVAL) }
            bytes.append(byte)
        }
        seen += 1
        stopped = bytes.count >= SemanticFilePolicy.contentBatchBytes + 4
    }
}
