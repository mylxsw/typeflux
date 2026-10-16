import Darwin
import Foundation
import PDFKit

extension AskFileWorkerCommand {
    /// Includes identity and nanosecond change time, so same-size replacements cannot reuse checkpoints.
    static func contentVersion(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    // Read only resident, regular, authorized files through the already checked descriptor.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func content(_ request: AskFileReadRequest, mounts: AskFileMounts) -> AskFileReadResponse {
        guard let scope = request.scope, scope.includes(request.path, isDirectory: false),
              SemanticFilePolicy.allows(request.path) else { return .init(error: EACCES) }
        if let mount = mounts.blocking(request.path) {
            return .init(skippedMounts: [mount])
        }
        let parent = openDirectory((request.path as NSString).deletingLastPathComponent,
                                   blocked: scope.blocked + mounts.excluded)
        guard parent >= 0 else { return .init(error: errno) }
        defer { close(parent) }
        let name = (request.path as NSString).lastPathComponent
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .init(error: errno) }
        guard AskFilePreviewPolicy.isResidentRegularFile(mode: info.st_mode, flags: info.st_flags)
        else { return .init(error: EINVAL) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .init(error: errno) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              AskFilePreviewPolicy.isResidentRegularFile(mode: opened.st_mode, flags: opened.st_flags)
        else { return .init(error: EAGAIN) }
        let version = contentVersion(opened)
        let modified = Date(timeIntervalSince1970: Double(opened.st_mtimespec.tv_sec)
            + Double(opened.st_mtimespec.tv_nsec) / 1e9)
        var result = AskFileReadResponse(fileSize: Int64(opened.st_size), modified: modified, version: version)
        guard request.readText else { return result }
        guard SemanticMediaPriority.of(request.path) == .document else { return .init(error: EINVAL) }
        let cursor = request.cursor ?? .init()
        guard cursor.page >= 0, cursor.offset >= 0 else { return .init(error: EINVAL) }
        if (request.path as NSString).pathExtension.lowercased() == "pdf" {
            // PDFKit reads lazily from the held descriptor. Never load a whole PDF into Data.
            // Decoder stalls remain confined to the disposable worker's existing deadline.
            guard let pdf = PDFDocument(url: URL(fileURLWithPath: "/dev/fd/\(descriptor)"))
            else { return .init(error: EILSEQ) }
            guard !pdf.isLocked else { return .init(error: EAUTH) }
            guard cursor.page <= pdf.pageCount else { return .init(error: EINVAL) }
            if cursor.page == pdf.pageCount {
                result.pages = []; return result
            }
            guard let page = pdf.page(at: cursor.page) else { return .init(error: EILSEQ) }
            let extracted: (text: String, kind: String)
            do { extracted = try SemanticPDFText.extract(page) } catch { return .init(error: EIO) }
            let bytes = Data(extracted.text.utf8)
            guard cursor.offset <= bytes.count else { return .init(error: EINVAL) }
            guard let part = contentSlice(bytes, offset: Int(cursor.offset)) else { return .init(error: EILSEQ) }
            result.pages = [.init(text: part.text, page: cursor.page + 1, offset: cursor.offset,
                                  segmentKind: extracted.kind)]
            if part.consumed < bytes.count - Int(cursor.offset) {
                result.nextCursor = .init(page: cursor.page, offset: cursor.offset + Int64(part.consumed))
            } else if cursor.page + 1 < pdf.pageCount {
                result.nextCursor = .init(page: cursor.page + 1)
            }
        } else if ["docx", "html", "htm", "rtf", "odt", "pptx"]
            .contains((request.path as NSString).pathExtension.lowercased()) {
            do {
                let batch: AskFileReadResponse
                if (request.path as NSString).pathExtension.lowercased() == "docx" {
                    batch = try SemanticWordText.read(descriptor: descriptor,
                        size: Int64(opened.st_size), cursor: cursor)
                } else if (request.path as NSString).pathExtension.lowercased() == "pptx" {
                    batch = try SemanticPresentationText.read(descriptor: descriptor,
                        size: Int64(opened.st_size), cursor: cursor)
                } else if (request.path as NSString).pathExtension.lowercased() == "odt" {
                    batch = try SemanticODTText.read(descriptor: descriptor,
                        size: Int64(opened.st_size), cursor: cursor)
                } else if (request.path as NSString).pathExtension.lowercased() == "rtf" {
                    batch = try SemanticRTFText.read(descriptor: descriptor,
                        size: Int64(opened.st_size), cursor: cursor)
                } else {
                    batch = try SemanticHTMLText.read(descriptor: descriptor,
                        size: Int64(opened.st_size), cursor: cursor)
                }
                result.pages = batch.pages
                result.nextCursor = batch.nextCursor
            } catch let error as SemanticDocumentError { return .init(error: error.code) } catch {
                return .init(error: EILSEQ)
            }
        } else {
            guard cursor.page == 0, cursor.offset <= opened.st_size,
                  lseek(descriptor, off_t(cursor.offset), SEEK_SET) >= 0 else { return .init(error: EINVAL) }
            var bytes = [UInt8](repeating: 0, count: SemanticFilePolicy.contentBatchBytes + 4)
            var count = 0
            while count < bytes.count {
                let read = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress!.advanced(by: count), $0.count - count)
                }
                if read < 0, errno == EINTR {
                    continue
                }
                guard read >= 0 else { return .init(error: errno) }
                if read == 0 {
                    break
                }
                count += read
            }
            let data = Data(bytes.prefix(count))
            guard !data.contains(where: { $0 == 0 || ($0 < 32 && ![9, 10, 13].contains($0)) }),
                  let part = contentSlice(data, offset: 0) else { return .init(error: EILSEQ) }
            result.pages = [.init(text: part.text, offset: cursor.offset)]
            if cursor.offset + Int64(part.consumed) < opened.st_size {
                result.nextCursor = .init(offset: cursor.offset + Int64(part.consumed))
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, contentVersion(after) == version else { return .init(error: EAGAIN) }
        return result
    }

    /// Bound IPC and preserve UTF-8 boundaries. Overlap adjacent batches so boundary words remain recallable.
    static func contentSlice(_ data: Data, offset: Int) -> (text: String, consumed: Int)? {
        let available = data.count - offset
        var count = min(SemanticFilePolicy.contentBatchBytes, available)
        let more = count < available
        if more {
            while count > 0, data[offset + count] & 0xC0 == 0x80 {
                count -= 1
            }
        }
        guard let text = String(data: data.subdata(in: offset ..< offset + count), encoding: .utf8) else { return nil }
        var consumed = count
        if more {
            consumed = max(1, count - 160)
            while consumed < count, data[offset + consumed] & 0xC0 == 0x80 {
                consumed += 1
            }
        }
        return (text, consumed)
    }
}
