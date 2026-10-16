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
                         info: AskFileReadResponse) async throws -> AskFilePreviewContent {
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
                    evidence: hit.evidence, cancellation: cancellation
                ) }.value
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) },
                                         pageCount: rendered.pages, pageNumbers: rendered.numbers)
        }
        if kind == .video || kind == .audio {
            return try await media(hit.url, kind: kind, pixels: pixels, start: hit.evidence?.time ?? 0)
        }
        let rendered = try await AskQuickLookThumbnail.decode(hit.url, pixels: pixels)
        try Task.checkCancellation()
        return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) })
    }

    private static func media(_ url: URL, kind: AskFilePreviewKind,
                              pixels: CGSize, start: TimeInterval) async throws -> AskFilePreviewContent {
        let cancellation = AskSearchCancellation()
        let rendered = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try MediaPreviewDisplay.renderAV(url, pixels: pixels, video: kind == .video,
                                                 start: start, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return AskFilePreviewContent(kind: kind, images: rendered.images.map { NSImage(cgImage: $0, size: .zero) },
                                     duration: rendered.duration, startTime: rendered.start, waveform: rendered.waveform)
    }
}
