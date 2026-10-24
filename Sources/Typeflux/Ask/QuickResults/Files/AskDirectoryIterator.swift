import Darwin
import Foundation

/// Reads names and attributes together on local filesystems. It never follows child symlinks.
/// A disposable file worker owns all syscalls, including the bulk call and its POSIX fallback.
final class AskDirectoryIterator {
    enum Strategy { case automatic, posix }
    typealias BulkRead = (Int32, inout attrlist, UnsafeMutableRawPointer, Int) -> Int32
    struct Item {
        var name: String
        var isDirectory: Bool
        var modified: Date?

        func entry(parent: Int32, path: String, scope: AskFileScope) -> AskFileCrawler.Entry? {
            guard let modified else {
                return AskFileWorkerCommand.entry(name, parent: parent, path: path, scope: scope)
            }
            let kind: AskFileRecord.Kind = isDirectory ? (AskFileCrawler.isPackage(path) ? .package : .folder) : .file
            return .init(path: path, kind: kind, modified: modified)
        }
    }

    private(set) var descriptor: Int32
    private var directory: UnsafeMutablePointer<DIR>?
    private let reopen: () -> Int32
    private let bulkRead: BulkRead
    private var bulk: Bool
    private var started = false
    private var items: [Item] = []
    private var position = 0
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 8)

    init(descriptor: Int32, strategy: Strategy = .automatic, reopen: @escaping () -> Int32,
         bulkRead: @escaping BulkRead = { descriptor, attributes, buffer, size in
             getattrlistbulk(descriptor, &attributes, buffer, size, UInt64(FSOPT_PACK_INVAL_ATTRS))
         }) throws {
        self.descriptor = descriptor; self.reopen = reopen; self.bulkRead = bulkRead
        bulk = strategy == .automatic
        if !bulk {
            directory = fdopendir(descriptor)
            if directory == nil { let code = errno; Darwin.close(descriptor); self.descriptor = -1; throw Self.error(code) }
        }
    }

    deinit {
        if let directory { closedir(directory) }
        else if descriptor >= 0 { Darwin.close(descriptor) }
        buffer.deallocate()
    }

    func next() throws -> Item? {
        if !bulk { return try nextPOSIX() }
        if position < items.count { defer { position += 1 }; return items[position] }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
        let count = bulkRead(descriptor, &attributes, buffer, 64 * 1024)
        if count < 0 {
            let code = errno
            guard !started, [ENOTSUP, EINVAL, ENOSYS].contains(code) else { throw Self.error(code) }
            // Never mix readdir and getattrlistbulk on the same open description.
            Darwin.close(descriptor); descriptor = reopen()
            guard descriptor >= 0 else { throw Self.error(errno) }
            directory = fdopendir(descriptor)
            guard directory != nil else {
                let code = errno; Darwin.close(descriptor); descriptor = -1; throw Self.error(code)
            }
            bulk = false
            return try nextPOSIX()
        }
        started = true
        guard count > 0 else { return nil }
        items = try Self.decode(UnsafeRawBufferPointer(start: buffer, count: 64 * 1024), count: Int(count))
        position = 0
        return try next()
    }

    private func nextPOSIX() throws -> Item? {
        guard let directory else { throw Self.error(EBADF) }
        errno = 0
        guard let item = readdir(directory) else {
            if errno != 0 { throw Self.error(errno) }
            return nil
        }
        let name = withUnsafePointer(to: &item.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        return Item(name: name, isDirectory: item.pointee.d_type == DT_DIR, modified: nil)
    }

    /// getattrlist packs fields on four-byte boundaries, including timespec and attrreference.
    static func decode(_ bytes: UnsafeRawBufferPointer, count: Int) throws -> [Item] {
        var result: [Item] = [], offset = 0
        for _ in 0 ..< count {
            guard offset + 56 <= bytes.count else { throw Self.error(EIO) }
            let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= 56, length <= bytes.count - offset else { throw Self.error(EIO) }
            let returned = bytes.loadUnaligned(fromByteOffset: offset + 4, as: attribute_set_t.self)
            let error = bytes.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)
            let name = bytes.loadUnaligned(fromByteOffset: offset + 28, as: attrreference_t.self)
            let start = 28 + Int(name.attr_dataoffset), size = Int(name.attr_length)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0,
                  start >= 56, size > 0, start <= length - size,
                  bytes[offset + start + size - 1] == 0 else { throw Self.error(EIO) }
            let filename = String(decoding: bytes[(offset + start) ..< (offset + start + size - 1)], as: UTF8.self)
            guard !filename.isEmpty, !filename.contains("/"), !filename.utf8.contains(0) else { throw Self.error(EIO) }
            let kind = bytes.loadUnaligned(fromByteOffset: offset + 36, as: UInt32.self)
            let modified = bytes.loadUnaligned(fromByteOffset: offset + 40, as: timespec.self)
            let valid = error == 0 && returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
                == attrgroup_t(ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
            result.append(Item(name: filename, isDirectory: kind == 2,
                               modified: valid ? Date(timeIntervalSince1970: TimeInterval(modified.tv_sec)) : nil))
            offset += length
        }
        return result
    }

    private static func error(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}
