import Darwin
import Foundation
import PDFKit

extension AskFileWorkerCommand {
    // Read only resident, regular, authorized files through the already checked descriptor.
    // Keep descriptor ownership and every pre-read security check in one scope.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func content(_ request: AskFileReadRequest, mounts: AskFileMounts) -> AskFileReadResponse {
        guard let scope = request.scope, scope.includes(request.path, isDirectory: false),
              SemanticFilePolicy.allows(request.path) else { return .init(error: EACCES) }
        if let mount = mounts.blocking(request.path) {
            return .init(skippedMounts: [mount])
        }
        let parent = openDirectory(
            (request.path as NSString).deletingLastPathComponent,
            blocked: scope.blocked + mounts.excluded
        )
        guard parent >= 0 else { return .init(error: errno) }
        defer { close(parent) }
        let name = (request.path as NSString).lastPathComponent
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              AskFilePreviewPolicy.isResidentRegularFile(mode: info.st_mode, flags: info.st_flags),
              info.st_size > 0,
              SemanticMediaPriority.of(request.path) != .document || info.st_size <= SemanticFilePolicy.maximumBytes
        else { return .init(error: EINVAL) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .init(error: errno) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              AskFilePreviewPolicy.isResidentRegularFile(mode: opened.st_mode, flags: opened.st_flags)
        else { return .init(error: EAGAIN) }
        let modified =
            Date(timeIntervalSince1970: Double(opened.st_mtimespec.tv_sec) + Double(opened.st_mtimespec.tv_nsec) / 1e9)
        if !request.readText {
            return .init(fileSize: Int64(opened.st_size), modified: modified)
        }
        guard SemanticMediaPriority.of(request.path) == .document else { return .init(error: EINVAL) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= SemanticFilePolicy.maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { return .init(error: errno) }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count <= SemanticFilePolicy.maximumBytes, fstat(descriptor, &after) == 0,
              after.st_size == opened.st_size, after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { return .init(error: EAGAIN) }
        var pages: [SemanticPage] = []
        if (request.path as NSString).pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { return .init(error: EILSEQ) }
            var remaining = 128_000
            for index in 0 ..< min(pdf.pageCount, 500) where remaining > 0 {
                let text = String((pdf.page(at: index)?.string ?? "").prefix(remaining))
                remaining -= text.count
                if !text.isEmpty {
                    pages.append(.init(text: text, page: index + 1))
                }
            }
        } else {
            guard !data.contains(where: { $0 == 0 || ($0 < 32 && ![9, 10, 13].contains($0)) }),
                  let text = String(data: data, encoding: .utf8) else { return .init(error: EILSEQ) }
            pages = [.init(text: String(text.prefix(128_000)))]
        }
        return .init(fileSize: Int64(opened.st_size), modified: modified, pages: pages)
    }
}
