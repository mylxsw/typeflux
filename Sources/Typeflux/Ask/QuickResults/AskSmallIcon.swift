import Darwin
import SwiftUI
import TypefluxMediaProtocol

/// No original-image parser runs in the host. Slots include uncooperative filesystem work.
enum AskSmallIconDecoder {
    enum Input: Sendable { case file(URL), data(Data) }
    typealias InputReader = @Sendable (Input) throws -> Data
    static let fileLimit = 4 * 1024 * 1024
    private static let admission = AskToolPixelBudget(limit: 2)
    static func decode(_ input: Input, worker: MediaWorker = .previews,
                       authorization original: MediaWorker.Authorization? = nil,
                       readInput: @escaping InputReader = { try read($0) }) async throws -> CGImage {
        try Task.checkCancellation()
        let authorization = original ?? worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let slot = try admission.acquire(bytes: 1), cancellation = AskSearchCancellation()
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || !worker.permits(authorization) }
        defer { withExtendedLifetime(slot) {} }
        return try await withTaskCancellationHandler {
            let image = try await Task.detached(priority: .utility) {
                if cancelled() { throw CancellationError() }
                let bytes = try readInput(input)
                if cancelled() { throw CancellationError() }
                let result = try MediaPreviewDisplay.renderImage(bytes, type: nil, cancellation: cancellation, worker: worker,
                                                               edge: 56, authorization: authorization)
                guard result.images.count == 1, let image = result.images.first,
                      image.width <= 56, image.height <= 56 else { throw MediaFailure.invalidProtocol }
                return image
            }.value
            try Task.checkCancellation()
            guard worker.permits(authorization) else { throw MediaFailure.unavailable }
            return image
        } onCancel: { cancellation.cancel() }
    }

    /// Bounded source preparation; this does not parse an image format or retain its source FD.
    static func read(_ input: Input) throws -> Data {
        switch input {
        case let .data(data):
            guard !data.isEmpty, data.count <= 262_144 else { throw MediaFailure.tooLarge }
            return data
        case let .file(url):
            guard url.isFileURL else { throw MediaFailure.unreadable }
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw MediaFailure.unreadable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= fileLimit else { throw MediaFailure.tooLarge }
            let bytes = try handle.read(upToCount: fileLimit + 1) ?? Data()
            guard !bytes.isEmpty, bytes.count <= fileLimit else { throw MediaFailure.tooLarge }
            return bytes
        }
    }
}

/// One accepted file-icon consumer, bound before Context's queued preparation.
struct AskSmallFileIconPreparation: Sendable {
    typealias Decoder = @Sendable (URL) async throws -> CGImage
    struct Batch: Sendable {
        let decode: @Sendable () async throws -> AskFilePreviewPDF.Result
        let isCurrent: @Sendable () -> Bool
    }
    let url: URL
    var decode: Decoder?
    var worker: MediaWorker = .previews
    var readInput: AskSmallIconDecoder.InputReader = { try AskSmallIconDecoder.read($0) }

    /// Memory-only snapshot; no input read, native work, or capacity is acquired here.
    func bind(_ source: String) -> Batch {
        let original = decode == nil ? worker.authorization() : nil
        let isCurrent: @Sendable () -> Bool = {
            !Task.isCancelled && (original.map { worker.permits($0) } ?? true)
        }
        return .init(decode: {
            guard isCurrent() else { throw MediaFailure.unavailable }
            guard source == url.absoluteString else { throw MediaFailure.unreadable }
            let image: CGImage
            if let decode { image = try await decode(url) }
            else { image = try await AskSmallIconDecoder.decode(.file(url), worker: worker, authorization: original, readInput: readInput) }
            guard isCurrent() else { throw MediaFailure.unavailable }
            return .init(images: [image], numbers: [], pages: 0)
        }, isCurrent: isCurrent)
    }
}

private struct AskIconGenerationKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var askIconGeneration: Int {
        get { self[AskIconGenerationKey.self] }
        set { self[AskIconGenerationKey.self] = newValue }
    }
}

fileprivate struct AskSmallIconDecoderOverride: Sendable {
    let decode: AskSmallFileIconPreparation.Decoder
}
private struct AskSmallIconDecoderKey: EnvironmentKey {
    static let defaultValue: AskSmallIconDecoderOverride? = nil
}
extension EnvironmentValues {
    var askSmallIconDecoder: @Sendable (URL) async throws -> CGImage {
        get {
            if let custom = self[AskSmallIconDecoderKey.self] { return custom.decode }
            return { @Sendable in try await AskSmallIconDecoder.decode(.file($0)) }
        }
        set { self[AskSmallIconDecoderKey.self] = .init(decode: newValue) }
    }
    fileprivate var smallFileIconDecoderOverride: AskSmallIconDecoderOverride? { self[AskSmallIconDecoderKey.self] }
}

struct AskSmallFileIcon: View {
    @Environment(\.smallFileIconDecoderOverride) private var decode
    let url: URL
    let symbol: String
    var filled = false
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.askIconGeneration) private var generation
    var body: some View {
        AskContextImage(source: url.absoluteString, model: AskContextImageModel(maximumEdge: 56,
            smallFileIcon: .init(url: url, decode: decode?.decode))) { image in
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { AskPluginItemIcon(icon: .symbol(symbol), symbol: symbol, filled: filled) }
        }
        .id(Identity(url: url, epoch: access.epoch, generation: generation))
        .frame(width: AskTheme.launcherResultIconSize, height: AskTheme.launcherResultIconSize)
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
