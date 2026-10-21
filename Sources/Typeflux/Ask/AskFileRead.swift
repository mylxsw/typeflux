import CryptoKit
import Darwin
import Foundation

/// A cursor is authenticated to reject inconsistent line/scan state without
/// rescanning a huge prefix. It expires on host restart and is never a grant.
enum AskFileRead {
    static let key = SymmetricKey(size: .bits256)
    static var restart: AskLocalError {
        .message("Cannot resume this read. Restart the read with a valid offset and limit.")
    }

    struct Cursor: Codable {
        var format = 1
        var root: String
        var rootIdentity: String
        var path: [String]
        var version: String
        var position: Int64 = 0
        var line = 0
        var partial = false
        var requestedLine: Int
        var remainingLines: Int
    }

    struct Envelope: Codable { var state: Cursor; var signature: String }
    static func signature(_ cursor: Cursor) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try Data(HMAC<SHA256>.authenticationCode(for: encoder.encode(cursor), using: key)).base64EncodedString()
    }

    static func encode(_ cursor: Cursor) throws -> String {
        let data = try JSONEncoder().encode(Envelope(state: cursor, signature: signature(cursor)))
        let token = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/",
            with: "_"
        ).replacingOccurrences(of: "=", with: "")
        guard token.utf8.count <= 4096 else { throw restart }
        return token
    }

    static func decode(_ token: String) throws -> Cursor {
        guard !token.isEmpty, token.utf8.count <= 4096,
              token.utf8
              .allSatisfy({
                  (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57)
                      .contains($0) || $0 == 45 || $0 == 95
              }) else { throw restart }
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let envelope = try? JSONDecoder().decode(
            Envelope.self,
            from: data
        ),
            envelope.state.format == 1, try envelope.signature == signature(envelope.state) else { throw restart }
        return envelope.state
    }

    struct Page {
        var text: String
        var numbered: String
        var path: String
        var version: String
        var continuation: String?
        var partial: Bool
        var scanning: Bool
        var eof: Bool
        var rendered: String {
            var result = "File: \(path)\nVersion: \(version)\n" + numbered
            if scanning {
                result += "\n[Requested line not reached; partial scan. Continue to advance.]"
            } else if partial {
                result += "\n[Partial line; continue to read the rest of this line.]"
            }
            if let continuation {
                result += "\nContinuation: \(continuation)"
            }
            if eof {
                result += "\n[End of file. Only consumed text was validated.]"
            }
            return result
        }
    }

    /// Scalar decoder uses fixed-size byte storage, so even a single grapheme
    /// containing millions of combining marks cannot allocate an unbounded line.
    final class Reader {
        let access: AskFileAccess
        var position: Int64
        let end: Int64
        let scanEnd: Int64
        var buffer = [UInt8]()
        var index = 0
        init(_ access: AskFileAccess, position: Int64) {
            self.access = access; self.position = position
            end = Int64(access.initial!.st_size)
            scanEnd = min(end, position + Int64(AskFileTools.maximumScanBytes))
        }

        func byte() throws -> UInt8? {
            if index == buffer.count {
                guard position < scanEnd else { return nil }
                try Task.checkCancellation()
                try access.hooks.onEvent?("read")
                buffer = [UInt8](repeating: 0, count: min(65536, Int(scanEnd - position)))
                var count: Int
                repeat {
                    count = pread(access.descriptor, &buffer, buffer.count, off_t(position))
                } while count < 0 &&
                    errno == EINTR
                guard count > 0 else {
                    throw AskFileAccess.conflict
                }
                try access.hooks.onBytes?(count)
                buffer.removeLast(buffer.count - count); index = 0
            }
            let value = buffer[index]; index += 1; position += 1
            return value
        }

        func scalar() throws -> [UInt8]? {
            let start = position
            guard let first = try byte() else { return nil }
            let count: Int
            switch first {
            case 1 ... 127: count = 1
            case 0xC2 ... 0xDF: count = 2
            case 0xE0 ... 0xEF: count = 3
            case 0xF0 ... 0xF4: count = 4
            default: throw AskFileAccess.error(L("ask.files.binary"))
            }
            var bytes = [first]
            for _ in 1 ..< count {
                guard let next = try byte() else {
                    // Budget boundary, not malformed data: resume before this scalar.
                    if scanEnd < end {
                        position = start; return nil
                    }
                    throw AskFileAccess.error(L("ask.files.binary"))
                }
                bytes.append(next)
            }
            guard String(bytes: bytes, encoding: .utf8) != nil else { throw AskFileAccess.error(L("ask.files.binary")) }
            return bytes
        }
    }

    static func page(_ access: AskFileAccess, offset: Int, limit: Int?, continuation: String?) throws -> Page {
        guard offset >= 0, offset <= AskFileTools.maximumPagingValue,
              (limit ?? 1) > 0, (limit ?? 1) <= AskFileTools.maximumPagingValue else { throw restart }
        var state = Cursor(root: access.location.root, rootIdentity: access.rootIdentity, path: access.location.parts,
                           version: access.version, requestedLine: offset,
                           remainingLines: limit ?? AskFileTools.maximumPagingValue)
        if let continuation {
            state = try decode(continuation)
            guard state.root == access.location.root, state.rootIdentity == access.rootIdentity,
                  state.path == access.location.parts, state.version == access.version,
                  state.position > 0, state.position < access.initial!.st_size,
                  state.line >= 0, state.line <= AskFileTools.maximumPagingValue,
                  state.requestedLine >= 0, state.requestedLine <= AskFileTools.maximumPagingValue,
                  state.remainingLines > 0, state.remainingLines <= AskFileTools.maximumPagingValue,
                  !state.partial || state.line >= state.requestedLine else { throw restart }
        }
        let initialPosition = state.position
        let reader = Reader(access, position: state.position)
        var text = Data(), numbered = Data()
        var needsPrefix = true
        while state.remainingLines > 0 {
            try Task.checkCancellation()
            let before = reader.position
            guard let scalar = try reader.scalar() else { break }
            if state.line < state.requestedLine {
                if scalar == [10] {
                    state.line += 1
                }
                state.position = reader.position
                continue
            }
            let prefix = needsPrefix ? Data("\(state.line + 1)\t".utf8) : Data()
            // Reserve space for the path, version, cursor and explanatory metadata.
            guard numbered.count + prefix.count + scalar.count <= 48000 else {
                state.position = before
                break
            }
            numbered.append(prefix); numbered.append(contentsOf: scalar); text.append(contentsOf: scalar)
            needsPrefix = scalar == [10]
            state.partial = scalar != [10]
            state.position = reader.position
            if scalar == [10] {
                state.line += 1; state.remainingLines -= 1
            }
        }
        let eof = state.position == access.initial!.st_size
        let truncated = !eof && state.remainingLines > 0
        guard !truncated || state.position > initialPosition else { throw restart }
        try access.hooks.onEvent?("release")
        try access.revalidate()
        let page = try Page(
            text: String(decoding: text, as: UTF8.self),
            numbered: String(decoding: numbered, as: UTF8.self),
            path: access.location.path,
            version: access.version,
            continuation: truncated ? encode(state) : nil,
            partial: !eof && state.partial,
            scanning: !eof && state.line < state.requestedLine,
            eof: eof
        )
        guard page.rendered.utf8.count <= AskFileTools.maximumReadCharacters else { throw restart }
        try Task.checkCancellation()
        return page
    }
}
