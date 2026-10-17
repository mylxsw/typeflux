import AppKit

/// Each reader belongs to one serial queue. Cancellation reaches its deadline-bound pipe loop.
private final class AskPreviewReader: @unchecked Sendable {
    let reader: any AskFileReading
    let queue = DispatchQueue(label: "typeflux.preview.reader", qos: .utility)
    init(_ reader: any AskFileReading) {
        self.reader = reader
    }

    func read(_ request: AskFileReadRequest) async throws -> AskFileReadResponse {
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(with: Result { try reader.read(
                        request,
                        isCancelled: { cancellation.isCancelled }
                    ) })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

@MainActor
enum AskFilePreviewRenderer {
    private static let reader = AskPreviewReader(AskFileReader(timeout: 2, startupTimeout: 3))

    static func metadata(_ hit: AskFileHit, readText: Bool) async throws -> AskFileReadResponse {
        try await reader.read(.init(operation: .preview, path: hit.path, readText: readText))
    }

    static func generate(_ hit: AskFileHit, kind: AskFilePreviewKind, pixels: CGSize,
                         info: AskFileReadResponse, worker: MediaWorker = .previews) async throws -> AskFilePreviewContent {
        if kind.readsText {
            guard let text = info.text else { throw AskFileReadError.unavailable }
            return AskFilePreviewContent(kind: kind, text: text, truncated: info.truncated == true)
        }
        // SVG uses the isolated Quick Look path below. Failed
        // bitmap/PDF decoding never falls back to parsing the original in the host.
        if kind == .pdf || (kind == .image && hit.url.pathExtension.lowercased() != "svg") {
            let cancellation = AskSearchCancellation()
            let rendered = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) { try MediaPreviewDisplay.render(
                    hit.url, pixels: pixels, pdf: kind == .pdf,
                    evidence: hit.evidence, cancellation: cancellation, worker: worker, version: info.version
                ) }.value
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) },
                                         pageCount: rendered.pages, pageNumbers: rendered.numbers,
                                         imageTextLocated: (kind == .image && hit.evidence?.segmentKind == "image-ocr")
                                            || (kind == .pdf && hit.evidence?.segmentKind == "pdf-ocr")
                                            ? rendered.imageTextLocated ?? false : nil)
        }
        if kind == .video || kind == .audio {
            let time = hit.mediaPreviewTime(version: info.version)
            let start = time ?? 0
            let mediaKind: AskFilePreviewKind = time != nil && hit.evidence?.segmentKind == "audio-window"
                ? .audio : kind
            let content: AskFilePreviewContent
            do {
                content = try await media(hit.url, kind: mediaKind, pixels: pixels, start: start, worker: worker)
            } catch {
                try Task.checkCancellation()
                guard start > 0 else { throw error }
                return try await media(hit.url, kind: mediaKind, pixels: pixels, start: 0, worker: worker)
            }
            if start > 0, start >= content.duration {
                return try await media(hit.url, kind: mediaKind, pixels: pixels, start: 0, worker: worker)
            }
            return content
        }
        let rendered = try await AskQuickLookThumbnail.decode(hit.url, pixels: pixels, worker: worker)
        try Task.checkCancellation()
        return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) })
    }

    private static func media(_ url: URL, kind: AskFilePreviewKind,
                              pixels: CGSize, start: TimeInterval, worker: MediaWorker) async throws -> AskFilePreviewContent {
        let cancellation = AskSearchCancellation()
        let rendered = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try MediaPreviewDisplay.renderAV(
                    url, pixels: pixels, video: kind == .video,
                    start: start, cancellation: cancellation, worker: worker)
            }.value
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) },
                                     duration: rendered.duration, startTime: rendered.start,
                                     waveform: rendered.waveform)
    }
}
