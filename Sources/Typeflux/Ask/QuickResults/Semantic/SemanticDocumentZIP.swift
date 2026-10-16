import Darwin
import Foundation
import zlib

struct SemanticDocumentError: Error {
    let code: Int32
    init(_ code: Int32 = EILSEQ) { self.code = code }
}

/// Reads one ZIP32 member from a held descriptor. No archive paths are materialized or followed.
enum SemanticDocumentZIP {
    struct Member {
        var offset: Int64
        var compressed: Int
        var expanded: Int
        var method: Int
        var crc: UInt32
    }

    static func bytes(_ descriptor: Int32, at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count), consumed = 0
        while consumed < count {
            let size = data.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress!.advanced(by: consumed), count - consumed, offset + Int64(consumed))
            }
            if size < 0, errno == EINTR { continue }
            guard size > 0 else { throw SemanticDocumentError() }
            consumed += size
        }
        return data
    }

    // ZIP's comment length is a 16-bit field; this is a format bound, not a document quota.
    // swiftlint:disable:next cyclomatic_complexity
    static func body(_ descriptor: Int32, size: Int64) throws -> Member {
        guard size >= 22 else { throw SemanticDocumentError() }
        let tail = try bytes(descriptor, at: max(0, size - 65557), count: Int(min(size, 65557)))
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.u32($0) == 0x06054B50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }) else { throw SemanticDocumentError(ENOTSUP) }
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10), tail.u16(end + 10) != 0xFFFF,
              tail.u32(end + 16) != 0xFFFF_FFFF else { throw SemanticDocumentError(ENOTSUP) }
        var offset = Int64(tail.u32(end + 16))
        let directoryEnd = offset + Int64(tail.u32(end + 12))
        guard directoryEnd <= size - Int64(tail.count - end) else { throw SemanticDocumentError() }
        var member: Member?
        for _ in 0 ..< Int(tail.u16(end + 10)) {
            guard offset + 46 <= directoryEnd else { throw SemanticDocumentError() }
            let header = try bytes(descriptor, at: offset, count: 46)
            guard header.u32(0) == 0x02014B50 else { throw SemanticDocumentError() }
            let nameSize = Int(header.u16(28))
            let next = offset + 46 + Int64(nameSize) + Int64(header.u16(30)) + Int64(header.u16(32))
            guard next <= directoryEnd else { throw SemanticDocumentError() }
            let name = try bytes(descriptor, at: offset + 46, count: nameSize)
            offset = next
            guard name == Data("word/document.xml".utf8) else { continue }
            guard member == nil else { throw SemanticDocumentError() }
            guard header.u16(8) & 0x41 == 0 else { throw SemanticDocumentError(EAUTH) }
            let method = Int(header.u16(10))
            guard [0, 8].contains(method), header.u16(34) == 0,
                  header.u32(20) != 0xFFFF_FFFF, header.u32(24) != 0xFFFF_FFFF,
                  header.u32(42) != 0xFFFF_FFFF else { throw SemanticDocumentError(ENOTSUP) }
            let localOffset = Int64(header.u32(42))
            guard localOffset + 30 <= Int64(tail.u32(end + 16)) else { throw SemanticDocumentError() }
            let local = try bytes(descriptor, at: localOffset, count: 30)
            guard local.u32(0) == 0x04034B50, local.u16(8) == method,
                  local.u16(6) == header.u16(8), Int(local.u16(26)) == nameSize,
                  try bytes(descriptor, at: localOffset + 30, count: nameSize) == name
            else { throw SemanticDocumentError() }
            let start = localOffset + 30 + Int64(local.u16(26)) + Int64(local.u16(28))
            guard start + Int64(header.u32(20)) <= Int64(tail.u32(end + 16))
            else { throw SemanticDocumentError() }
            member = .init(offset: start, compressed: Int(header.u32(20)), expanded: Int(header.u32(24)),
                           method: method, crc: header.u32(16))
        }
        guard offset == directoryEnd, let member else { throw SemanticDocumentError() }
        return member
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

/// Inflate into the XML parser's small read buffer; memory does not grow with archive/document size.
final class SemanticDocumentStream: InputStream {
    private let descriptor: Int32
    private let member: SemanticDocumentZIP.Member
    private var inflater = z_stream()
    private var input = Data()
    private var position = 0
    private var compressedRead = 0
    private var expandedRead = 0
    private var checksum: uLong = 0
    private var ended = false
    private var failure: Error?
    private var scanTail = Data()

    init(descriptor: Int32, member: SemanticDocumentZIP.Member) throws {
        self.descriptor = descriptor; self.member = member
        super.init(data: Data())
        if member.method == 8 {
            guard inflateInit2_(&inflater, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
            else { throw SemanticDocumentError() }
        }
    }

    deinit { if member.method == 8 { inflateEnd(&inflater) } }
    override func open() {}
    override func close() {}
    override var streamStatus: Stream.Status { failure != nil ? .error : ended ? .atEnd : .open }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { !ended && failure == nil }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool { false }

    // swiftlint:disable:next cyclomatic_complexity
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard failure == nil else { return -1 }
        guard !ended, len > 0 else { return 0 }
        do {
            var produced = 0
            while produced == 0, !ended {
                if position == input.count, compressedRead < member.compressed {
                    input = try SemanticDocumentZIP.bytes(descriptor, at: member.offset + Int64(compressedRead),
                                                         count: min(32768, member.compressed - compressedRead))
                    compressedRead += input.count; position = 0
                }
                if member.method == 0 {
                    produced = min(len, input.count - position)
                    input.copyBytes(to: buffer, from: position ..< position + produced)
                    position += produced
                    ended = position == input.count && compressedRead == member.compressed
                } else {
                    let available = input.count - position
                    let status = input.withUnsafeBytes { bytes -> Int32 in
                        inflater.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self)
                            .baseAddress?.advanced(by: position))
                        inflater.avail_in = uInt(available)
                        inflater.next_out = buffer; inflater.avail_out = uInt(len)
                        return inflate(&inflater, Z_NO_FLUSH)
                    }
                    position += available - Int(inflater.avail_in)
                    produced = len - Int(inflater.avail_out)
                    inflater.next_in = nil; inflater.next_out = nil
                    guard status == Z_OK || status == Z_STREAM_END,
                          produced > 0 || position < input.count || compressedRead < member.compressed
                          || status == Z_STREAM_END else { throw SemanticDocumentError() }
                    ended = status == Z_STREAM_END
                }
            }
            expandedRead += produced
            guard expandedRead <= member.expanded else { throw SemanticDocumentError() }
            checksum = crc32(checksum, buffer, uInt(produced))
            if ended {
                guard expandedRead == member.expanded, UInt32(checksum) == member.crc,
                      position == input.count, compressedRead == member.compressed
                else { throw SemanticDocumentError() }
            }
            // DOCX XML must be UTF-8. Reject DTDs before XMLParser can expand any entities,
            // including declarations split across input buffers. No relationship is dereferenced.
            let scan = scanTail + Data(bytes: buffer, count: produced)
            guard !scan.contains(0), scan.range(of: Data("<!DOCTYPE".utf8)) == nil,
                  scan.range(of: Data("<!ENTITY".utf8)) == nil else { throw SemanticDocumentError(ENOTSUP) }
            scanTail = Data(scan.suffix(10))
            return produced
        } catch { failure = error; return -1 }
    }
}
