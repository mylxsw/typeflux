import SwiftUI
import TypefluxMediaProtocol

enum AskQuickLookThumbnail {
    private static let admission = AskToolPixelBudget(limit: 2)
    static func decode(_ url: URL, pixels: CGSize, iconFallback: Bool = false,
                       worker: MediaWorker = .previews) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        guard url.isFileURL else { throw MediaFailure.invalidProtocol }
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width >= 1, pixels.height >= 1,
              pixels.width <= 4096, pixels.height <= 4096 else { throw MediaFailure.tooLarge }
        let options = MediaPreviewOptions(width: Int(pixels.width), height: Int(pixels.height))
        try options.validate()
        let target = MediaQuickLook(path: url.path, representation: iconFallback ? .all : .thumbnail)
        try target.validate()
        let slot = try admission.acquire(bytes: 1)
        let memory = try AskToolPixelBudget.shared.acquire(bytes: options.width * options.height * 4)
        defer { withExtendedLifetime((slot, memory)) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                try MediaPreviewDisplay.renderQuickLook(target, options: options, cancellation: cancellation, worker: worker)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
}

typealias AskQuickLookDecoding = @Sendable (URL, CGSize) async throws -> AskFilePreviewPDF.Result
private struct AskQuickLookDecoderKey: EnvironmentKey {
    static let defaultValue: AskQuickLookDecoding = { try await AskQuickLookThumbnail.decode($0, pixels: $1, iconFallback: true) }
}
extension EnvironmentValues {
    var askQuickLookDecoder: AskQuickLookDecoding {
        get { self[AskQuickLookDecoderKey.self] }
        set { self[AskQuickLookDecoderKey.self] = newValue }
    }
}

/// No global thumbnail cache or prefetch: pixels belong to the authorized visible row.
struct AskQuickLookThumbnailView: View {
    let url: URL
    var modified: Date?
    var scale: CGFloat = 2
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.askIconGeneration) private var generation
    @Environment(\.askQuickLookDecoder) private var decode
    private var edge: Int? { scale.isFinite && scale >= 1 && scale <= 4 ? Int(ceil(56 * scale)) : nil }
    var body: some View {
        let edge = self.edge, decode = self.decode, url = self.url
        return AskContextImage(source: edge == nil ? nil : url.absoluteString,
            model: AskContextImageModel(maximumEdge: 224, decode: { _ in
                guard let edge else { throw MediaFailure.tooLarge }
                return try await decode(url, .init(width: edge, height: edge))
            })) { image in
                if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
                else { AskNativeIconView(icon: .init(kind: .file, value: url.path), revision: modified) }
            }
            .id(Identity(url: url, modified: modified, edge: edge, epoch: access.epoch, generation: generation))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    private struct Identity: Hashable {
        let url: URL; let modified: Date?; let edge: Int?; let epoch: UUID?; let generation: Int
    }
}
