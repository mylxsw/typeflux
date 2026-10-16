import Darwin
import SwiftUI
import TypefluxMediaProtocol

/// No original-image parser runs in the host. Slots include uncooperative filesystem work.
enum AskSmallIconDecoder {
    enum Input: Sendable { case file(URL), data(Data) }
    static let fileLimit = 4 * 1024 * 1024
    private static let admission = AskToolPixelBudget(limit: 2)
    static func decode(_ input: Input, worker: MediaWorker = .previews) async throws -> CGImage {
        try Task.checkCancellation()
        let slot = try admission.acquire(bytes: 1), cancellation = AskSearchCancellation()
        defer { withExtendedLifetime(slot) {} }
        return try await withTaskCancellationHandler {
            let image = try await Task.detached(priority: .utility) {
                if cancellation.isCancelled { throw CancellationError() }
                let bytes: Data
                switch input {
                case let .data(data):
                    guard !data.isEmpty, data.count <= 262_144 else { throw MediaFailure.tooLarge }
                    bytes = data
                case let .file(url):
                    guard url.isFileURL else { throw MediaFailure.unreadable }
                    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw MediaFailure.unreadable }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          info.st_size > 0, info.st_size <= fileLimit else { throw MediaFailure.tooLarge }
                    bytes = try handle.read(upToCount: fileLimit + 1) ?? Data()
                    guard !bytes.isEmpty, bytes.count <= fileLimit else { throw MediaFailure.tooLarge }
                }
                let result = try MediaPreviewDisplay.renderImage(bytes, type: nil, cancellation: cancellation, worker: worker, edge: 56)
                guard result.images.count == 1, let image = result.images.first,
                      image.width <= 56, image.height <= 56 else { throw MediaFailure.invalidProtocol }
                return image
            }.value
            try Task.checkCancellation()
            return image
        } onCancel: { cancellation.cancel() }
    }
}

private struct AskIconGenerationKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var askIconGeneration: Int {
        get { self[AskIconGenerationKey.self] }
        set { self[AskIconGenerationKey.self] = newValue }
    }
}

struct AskSmallFileIcon: View {
    let url: URL
    let symbol: String
    var filled = false
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.askIconGeneration) private var generation
    var body: some View {
        AskContextImage(source: url.absoluteString, model: AskContextImageModel(maximumEdge: 56, decode: { _ in
            let image = try await AskSmallIconDecoder.decode(.file(url))
            return .init(images: [image], numbers: [], pages: 0)
        })) { image in
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { AskPluginItemIcon(icon: .symbol(symbol), symbol: symbol, filled: filled) }
        }
        .id(Identity(url: url, epoch: access.epoch, generation: generation))
        .frame(width: 26, height: 26)
    }
    private struct Identity: Hashable { let url: URL; let epoch: UUID?; let generation: Int }
}

/// Explicit local editor scope. A new run creates a new view identity; closing revokes it.
struct AskLocalIconScope<Content: View>: View {
    let content: Content
    @State private var scope: AskImagePresentationScope
    @State private var epoch: UUID
    init(@ViewBuilder content: () -> Content) {
        let scope = AskImagePresentationScope()
        _scope = State(initialValue: scope); _epoch = State(initialValue: scope.epoch)
        self.content = content()
    }
    var body: some View {
        content.environment(\.askContextImageAccess, .init(scope: scope, epoch: epoch, authorize: { true }))
            .onAppear { scope.setVisible(true); epoch = scope.epoch }
            .onDisappear { scope.setVisible(false) }
    }
}
