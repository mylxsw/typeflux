import SwiftUI
import TypefluxMediaProtocol

/// No app-lifetime pixel cache. Visible, authorized views own each projection.
enum ClipboardThumbnailProvider {
    static let maximumEdge = 900
    private static let admission = AskToolPixelBudget(limit: 2)
    static func decode(_ url: URL, edge: CGFloat, worker: MediaWorker = .clipboardThumbnails) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        guard url.isFileURL, url.path.utf8.count <= 4096, !url.path.contains("\0"),
              edge.isFinite, edge >= 1, edge <= CGFloat(maximumEdge) else { throw MediaFailure.invalidProtocol }
        let slot = try admission.acquire(bytes: 1)
        let pixels = try AskToolPixelBudget.shared.acquire(bytes: Int(edge) * Int(edge) * 4)
        defer { withExtendedLifetime((slot, pixels)) {} }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                if cancellation.isCancelled { throw CancellationError() }
                let options = MediaPreviewOptions(width: Int(edge), height: Int(edge))
                // An extension chooses the adapter, never grants proof that the bytes are valid.
                if ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "heif", "bmp", "ico", "icns", "avif"].contains(url.pathExtension.lowercased()) {
                    return try MediaPreviewDisplay.render(url, pixels: .init(width: Int(edge), height: Int(edge)),
                        pdf: false, evidence: nil, cancellation: cancellation, worker: worker)
                }
                return try MediaPreviewDisplay.renderQuickLook(.init(path: url.path, representation: .all),
                    options: options, cancellation: cancellation, worker: worker)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
}

typealias ClipboardThumbnailDecoding = @Sendable (URL, CGFloat) async throws -> AskFilePreviewPDF.Result
private struct ClipboardThumbnailDecoderKey: EnvironmentKey {
    static let defaultValue: ClipboardThumbnailDecoding = { try await ClipboardThumbnailProvider.decode($0, edge: $1) }
}
extension EnvironmentValues {
    var clipboardThumbnailDecoder: ClipboardThumbnailDecoding {
        get { self[ClipboardThumbnailDecoderKey.self] }
        set { self[ClipboardThumbnailDecoderKey.self] = newValue }
    }
}

/// Panel-local authorization: a reused entry ID or a new window session cannot bless old pixels.
@MainActor final class ClipboardThumbnailSession: ObservableObject {
    let scope = AskImagePresentationScope()
    @Published private(set) var revision = UUID()
    private weak var model: ClipboardPanelModel?
    private var active = false
    func begin(_ model: ClipboardPanelModel) {
        end(); self.model = model; active = true; scope.setVisible(true); revision = UUID()
    }
    func changed() { scope.invalidate(); revision = UUID() }
    func end() { active = false; model = nil; scope.setVisible(false); revision = UUID() }
    func access(for entry: ClipboardEntry?) -> AskImagePresentationAccess {
        guard let entry, active else { return .init() }
        return .init(scope: scope, epoch: scope.epoch, authorize: { [weak self] in
            guard let self, active, let model else { return false }
            return model.entries.contains(entry)
        })
    }
}
