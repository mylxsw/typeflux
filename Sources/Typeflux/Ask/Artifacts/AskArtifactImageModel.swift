import AppKit
import TypefluxMediaProtocol

enum AskArtifactPresentation {
    private static let admission = ArtifactImageAdmission()
    /// Only raw, validated pixels cross back into the UI process.
    static func image(_ data: Data, mediaType: String, worker: MediaWorker = .previews,
                      authorization original: MediaWorker.Authorization? = nil) async throws -> AskFilePreviewPDF.Result {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= AskArtifactStore.maximumFileBytes else { throw AskArtifactError.tooLarge }
        guard let type = MediaImageType(rawValue: mediaType) else { throw AskArtifactError.unsupported }
        let authorization = original ?? worker.authorization()
        guard worker.permits(authorization) else { throw AskArtifactError.unavailable }
        guard admission.enter() else { throw AskArtifactError.unavailable }
        defer { admission.leave() }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let result = try await Task.detached(priority: .utility) {
                    guard !cancellation.isCancelled, worker.permits(authorization) else { throw CancellationError() }
                    return try MediaPreviewDisplay.renderImage(data, type: type, cancellation: cancellation, worker: worker,
                                                              authorization: authorization)
                }.value
                try Task.checkCancellation()
                guard worker.permits(authorization) else { throw AskArtifactError.unavailable }
                return result
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Never expose decoder errors, child output or private paths.
                throw (error as? MediaFailure) == .unreadable ? AskArtifactError.corrupt : AskArtifactError.unavailable
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// One view-owned projection. Decoding never grants access or repeats the producing tool.
@MainActor final class AskArtifactImageModel: ObservableObject {
    typealias Decoder = @Sendable (Data, String) async throws -> AskFilePreviewPDF.Result
    @Published private(set) var image: NSImage?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    struct Projection {
        var image: NSImage?
        var error: String?
        var busy: Bool
    }
    private var source: AskArtifactRef?
    private var imageSource: AskArtifactRef?
    private var originalSource: AskArtifactImageSource?
    private var imageIdentity: AskArtifactImageSource.Identity?
    private var generation = UUID()
    private let decode: Decoder?
    private let worker: MediaWorker
    private let write: @MainActor (Data, String) -> Bool

    init(worker: MediaWorker = .previews, decode: Decoder? = nil,
         write: @escaping @MainActor (Data, String) -> Bool = { writeImage($0, mediaType: $1) }) {
        self.worker = worker; self.decode = decode; self.write = write
    }

    static func writeImage(_ data: Data, mediaType: String, pasteboard: NSPasteboard = .general) -> Bool {
        guard let type = MediaImageType(rawValue: mediaType) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .init(type.identifier))
    }

    func load(_ ref: AskArtifactRef, access: AskArtifactAccess) async {
        await perform(ref, access: access, copying: false)
    }

    func copy(_ ref: AskArtifactRef, access: AskArtifactAccess) async {
        guard !busy else { return }
        await perform(ref, access: access, copying: true)
    }

    /// A source projection only. Filesystem access remains explicit in load/copy.
    func projection(for ref: AskArtifactRef, access: AskArtifactAccess = .init()) -> Projection {
        let empty = Projection(image: nil, error: nil, busy: false), current = generation
        guard source == ref, originalSource?.identity == access.imageSource?.identity else { return empty }
        let fresh = access.imageSource?.allows(ref) ?? true
        guard !Task.isCancelled, generation == current else { return empty }
        // Sample the retained owner last: fresh access cannot bless retired pixels.
        let original = originalSource?.allows(ref) ?? true
        guard !Task.isCancelled, generation == current else { return empty }
        guard fresh && original else { return .init(image: nil, error: AskArtifactError.denied.localizedDescription, busy: false) }
        return .init(image: imageSource == ref && imageIdentity == originalSource?.identity ? image : nil, error: error, busy: busy)
    }

    func cancel() {
        generation = UUID(); source = nil; imageSource = nil; originalSource = nil; imageIdentity = nil
        image = nil; error = nil; busy = false
    }

    private func perform(_ ref: AskArtifactRef, access: AskArtifactAccess, copying: Bool) async {
        guard !Task.isCancelled else { return }
        let authorization = decode == nil ? worker.authorization() : nil
        let entry = generation
        let permitted = access.imageSource?.allows(ref) ?? true
        guard !Task.isCancelled, generation == entry else { return }
        if !permitted, let source {
            let owned = originalSource?.allows(source) ?? true
            guard !Task.isCancelled, generation == entry else { return }
            if owned { return }
        }
        let current = UUID(); generation = current
        source = ref; originalSource = access.imageSource
        busy = true; error = nil
        if !copying { imageSource = nil; image = nil }
        defer { if generation == current { busy = false } }
        do {
            try Task.checkCancellation()
            guard permitted else { throw AskArtifactError.denied }
            try access.validate(ref)
            try Task.checkCancellation()
            guard owns(ref, current: current) else { return }
            if let authorization, !worker.permits(authorization) { throw AskArtifactError.unavailable }
            let bundle = try access.load(ref)
            try Task.checkCancellation()
            guard owns(ref, current: current) else { return }
            if let authorization, !worker.permits(authorization) { throw AskArtifactError.unavailable }
            guard bundle.manifest.ref == ref, let data = bundle.files[bundle.manifest.entry],
                  MediaImageType(rawValue: ref.mediaType) != nil,
                  data.count <= AskArtifactStore.maximumFileBytes,
                  AskToolPolicy.digest(data) == ref.sha256 else { throw AskArtifactError.corrupt }
            let result: AskFilePreviewPDF.Result
            if let decode { result = try await decode(data, ref.mediaType) }
            else { result = try await AskArtifactPresentation.image(data, mediaType: ref.mediaType, worker: worker, authorization: authorization) }
            try Task.checkCancellation()
            guard owns(ref, current: current) else { return }
            // Account, conversation, grant or expiry may have changed during decoding.
            try access.validate(ref)
            try Task.checkCancellation()
            guard owns(ref, current: current) else { return }
            if let authorization, !worker.permits(authorization) { throw AskArtifactError.unavailable }
            guard let pixels = result.images.first else { throw AskArtifactError.corrupt }
            if copying, !write(data, ref.mediaType) { throw AskArtifactError.unavailable }
            // An entered copy cannot be undone, but its callback may retire this attempt.
            try Task.checkCancellation()
            guard owns(ref, current: current) else { return }
            imageSource = ref; imageIdentity = originalSource?.identity; image = NSImage(cgImage: pixels, size: .zero)
        } catch {
            guard generation == current else { return }
            if Task.isCancelled || error is CancellationError { return }
            let failure = (error as? AskArtifactError) ?? .unavailable
            if failure == .denied || failure == .expired { imageSource = nil; image = nil }
            self.error = failure.localizedDescription
        }
    }

    private func owns(_ ref: AskArtifactRef, current: UUID) -> Bool {
        guard !Task.isCancelled, generation == current else { return false }
        let permitted = originalSource?.allows(ref) ?? true
        return !Task.isCancelled && generation == current && permitted
    }
}

/// Bound retained inputs and queued tasks before dispatching to the shared preview pool.
private final class ArtifactImageAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    func enter() -> Bool {
        lock.withLock { guard active < 2 else { return false }; active += 1; return true }
    }
    func leave() { lock.withLock { active -= 1 } }
}
