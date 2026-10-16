import Darwin
import Foundation
import TypefluxMediaProtocol

struct ClipboardMediaInfo: Equatable, Sendable {
    var duration: TimeInterval?
    var pageCount: Int?
}

/// Private child inputs/results are bounded; no app-lifetime path-only cache.
final class ClipboardMediaInfoProvider: @unchecked Sendable {
    static let shared = ClipboardMediaInfoProvider()
    static let waveformScanLimit = MediaClipboardOptions.scanSeconds
    static let waveformResolution = MediaClipboardOptions.buckets
    private static let admission = AskToolPixelBudget(limit: 2)
    private let worker: MediaWorker
    typealias SourceReader = @Sendable (URL) throws -> Stamp
    private let readSource: SourceReader
    init(worker: MediaWorker = .clipboardMetadata,
         readSource: @escaping SourceReader = { try Stamp($0) }) {
        self.worker = worker; self.readSource = readSource
    }

    struct Request: Hashable, Sendable {
        let url: URL
        let options: MediaClipboardOptions
        static func info(_ entry: ClipboardEntry) -> Self? {
            guard let url = entry.fileURLs.first else { return nil }
            switch entry.kind {
            case .pdf: return .init(url: url, options: .init(kind: .pdf))
            case .video, .audio: return .init(url: url, options: .init(kind: .duration, container: MediaAVContainer(rawValue: url.pathExtension.lowercased())))
            default: return nil
            }
        }
        static func waveform(_ url: URL?) -> Self? {
            url.map { .init(url: $0, options: .init(kind: .waveform, container: MediaAVContainer(rawValue: $0.pathExtension.lowercased()))) }
        }
    }
    func load(_ request: Request) async throws -> MediaClipboardResult {
        try Task.checkCancellation()
        guard request.url.isFileURL, request.url.path.utf8.count <= 4096, !request.url.path.contains("\0") else { throw MediaFailure.invalidProtocol }
        try request.options.validate()
        let authorization = worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation(), worker = self.worker, readSource = self.readSource
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                if cancelled() { throw CancellationError() }
                let before = try readSource(request.url)
                if cancelled() { throw CancellationError() }
                let value = try worker.perform(.clipboardMedia, input: .file(request.url), clipboard: request.options,
                    authorization: authorization, isCancelled: cancelled) { response, _ in
                        guard let value = response.clipboard else { throw MediaFailure.invalidProtocol }
                        return value
                    }
                guard before == (try readSource(request.url)) else { throw MediaFailure.unreadable }
                if cancelled() { throw CancellationError() }
                return value
            }.value
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            return result
        } onCancel: { cancellation.cancel() }
    }
    func info(for url: URL, kind: ClipboardEntryKind) async -> ClipboardMediaInfo? {
        let options: MediaClipboardOptions
        switch kind {
        case .pdf: options = .init(kind: .pdf)
        case .video, .audio: options = .init(kind: .duration, container: MediaAVContainer(rawValue: url.pathExtension.lowercased()))
        default: return nil
        }
        return try? await load(.init(url: url, options: options)).info
    }
    func loadInfo(for entry: ClipboardEntry) async -> ClipboardMediaInfo? {
        guard let request = Request.info(entry) else { return nil }
        return try? await load(request).info
    }
    func waveform(for url: URL, bars: Int) async -> [Float]? {
        guard (1...Self.waveformResolution).contains(bars), let request = Request.waveform(url),
              let value = try? await load(request), let levels = value.waveform else { return nil }
        return Self.resample(levels, to: bars)
    }
    static func resample(_ levels: [Float], to bars: Int) -> [Float] {
        guard (1...waveformResolution).contains(bars), !levels.isEmpty, levels.count <= waveformResolution,
              levels.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return [] }
        if levels.count == bars { return levels }
        return (0..<bars).map { index in
            let start = index * levels.count / bars
            let end = max((index + 1) * levels.count / bars, start + 1)
            return levels[start..<min(end, levels.count)].max() ?? 0
        }
    }
    struct Stamp: Equatable, Sendable {
        let device: dev_t; let inode: ino_t; let bytes: off_t
        let modified: Int; let modifiedNanos: Int; let changed: Int; let changedNanos: Int
        init(_ url: URL) throws {
            var info = stat(), mount = statfs()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_flags & UInt32(SF_DATALESS) == 0, statfs(url.path, &mount) == 0,
                  mount.f_flags & UInt32(MNT_LOCAL) != 0 else { throw MediaFailure.unreadable }
            device = info.st_dev; inode = info.st_ino; bytes = info.st_size
            modified = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changed = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
}

extension MediaClipboardResult {
    var info: ClipboardMediaInfo { .init(duration: duration, pageCount: pages) }
}
