import CryptoKit
import Darwin
import Foundation
import TypefluxMediaProtocol

/// Inspection happens after the producer has run. Its original output is never replayed or discarded.
enum AskWorkflowImage {
    static let maximumDataBytes = MediaWorkflowImage.inputBytes
    private static let admission = AskToolPixelBudget(limit: 2)
    private static let clipboardBudget = AskToolPixelBudget(limit: MediaWorkflowImage.copyBytes * 2)
    enum Failure: Error, Equatable { case notFound(String), notImage, unavailable }

    static func resolve(_ stdout: String, folder: URL, cache: URL, home: String,
                        worker: MediaWorker = .previews) async -> Result<AskPluginImage, Failure> {
        do {
            return .success(try await work { cancellation in
                guard stdout.utf8.count <= maximumDataBytes * 2 else { throw Failure.notImage }
                let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let data: Data, source: URL?
                if text.lowercased().hasPrefix("data:") {
                    guard let decoded = dataURL(text) else { throw Failure.notImage }
                    data = decoded; source = nil
                } else {
                    let line = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let path = line.hasPrefix("file://") ? URL(string: line)?.path ?? line : line
                    guard !path.isEmpty, let url = AskWorkflowActionRunner.file(path, folder: folder, home: home),
                          FileManager.default.fileExists(atPath: url.path) else { throw Failure.notFound(line) }
                    data = try read(url); source = url
                }
                let response = try worker.decode(.inspectWorkflowImage, input: .data(data), isCancelled: { cancellation.isCancelled })
                guard let metadata = response.workflowImage else { throw MediaFailure.invalidProtocol }
                if cancellation.isCancelled { throw CancellationError() }
                let digest = hash(data)
                let url = try source ?? save(data, digest: digest, type: metadata.format, cache: cache)
                return AskPluginImage(url: url, width: Double(metadata.width) / Double(metadata.scale),
                                      height: Double(metadata.height) / Double(metadata.scale), digest: digest)
            })
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure((error as? MediaFailure) == .unreadable || (error as? MediaFailure) == .tooLarge ? .notImage : .unavailable) }
    }

    static func dataURL(_ text: String) -> Data? {
        guard text.utf8.count <= maximumDataBytes * 2, let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[..<comma].lowercased()
        guard header.hasPrefix("data:image/"), header.hasSuffix(";base64") else { return nil }
        let payload = text[text.index(after: comma)...].filter { !$0.isWhitespace }
        guard payload.count <= maximumDataBytes / 3 * 4 + 4,
              let data = Data(base64Encoded: String(payload)), !data.isEmpty, data.count <= maximumDataBytes else { return nil }
        return data
    }

    static func render(_ image: AskPluginImage, worker: MediaWorker = .previews) async throws -> AskFilePreviewPDF.Result {
        try await work { cancellation in
            let data = try read(image.url)
            guard image.digest == nil || hash(data) == image.digest else { throw MediaFailure.unreadable }
            return try MediaPreviewDisplay.renderImage(data, type: nil, cancellation: cancellation, worker: worker)
        }
    }

    struct Clipboard: @unchecked Sendable {
        let png: Data
        let tiff: Data
        let reservation: AskToolPixelBudget.Lease
    }
    static func clipboard(_ url: URL, digest: String? = nil, worker: MediaWorker = .previews) async throws -> Clipboard {
        let reservation = try clipboardBudget.acquire(bytes: MediaWorkflowImage.copyBytes)
        return try await work { cancellation in
            let data = try read(url)
            guard digest == nil || hash(data) == digest else { throw MediaFailure.unreadable }
            return try worker.perform(.copyWorkflowImage, input: .data(data), isCancelled: { cancellation.isCancelled }) { response, fd in
                guard let metadata = response.workflowImage, let pngSize = metadata.pngBytes, let tiffSize = metadata.tiffBytes else { throw MediaFailure.invalidProtocol }
                let directory = AskSecureDirectory(descriptor: dup(fd))
                let png = try directory.readFile("clipboard-png", limit: pngSize)
                let tiff = try directory.readFile("clipboard-tiff", limit: tiffSize)
                guard png.count == pngSize, tiff.count == tiffSize,
                      png.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]),
                      tiff.starts(with: [0x49, 0x49, 42, 0]) || tiff.starts(with: [0x4d, 0x4d, 0, 42]) else { throw MediaFailure.invalidProtocol }
                return Clipboard(png: png, tiff: tiff, reservation: reservation)
            }
        }
    }

    static func work<T: Sendable>(_ operation: @escaping @Sendable (AskSearchCancellation) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let slot = try admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                if cancellation.isCancelled { throw CancellationError() }
                return try operation(cancellation)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw MediaFailure.unreadable }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MediaFailure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumDataBytes else { throw MediaFailure.tooLarge }
        let data = try handle.read(upToCount: maximumDataBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumDataBytes else { throw MediaFailure.tooLarge }
        return data
    }
    private static func save(_ data: Data, digest: String, type: MediaWorkflowFormat, cache: URL) throws -> URL {
        let directory = try AskSecureDirectory.openRoot(cache.appendingPathComponent("images"))
        try directory.lock()
        let name = String(digest.prefix(24)) + "." + type.fileExtension
        let entries = directory.entries(limit: 129)
        if entries.contains(name) {
            guard try directory.readFile(name, limit: maximumDataBytes) == data else { throw MediaFailure.unreadable }
        } else {
            guard entries.count < 128 else { throw MediaFailure.unavailable }
            var size = data.count
            for entry in entries {
                var info = stat()
                guard fstatat(directory.descriptor, entry, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximumDataBytes else { throw MediaFailure.unavailable }
                size += Int(info.st_size)
            }
            guard size <= 256 * 1024 * 1024 else { throw MediaFailure.unavailable }
            try directory.createFile(name, data: data)
        }
        return try directory.url.appendingPathComponent(name)
    }
}
