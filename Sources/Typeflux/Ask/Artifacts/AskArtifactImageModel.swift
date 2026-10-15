import AppKit
import TypefluxMediaProtocol

enum AskArtifactPresentation {
    private static let admission = ArtifactImageAdmission()
    /// Only raw, validated pixels cross back into the UI process.
    static func image(_ data: Data, mediaType: String, worker: MediaWorker = .previews) async throws -> AskFilePreviewPDF.Result {
        guard !data.isEmpty, data.count <= AskArtifactStore.maximumFileBytes else { throw AskArtifactError.tooLarge }
        guard let type = MediaImageType(rawValue: mediaType) else { throw AskArtifactError.unsupported }
        guard admission.enter() else { throw AskArtifactError.unavailable }
        defer { admission.leave() }
        let cancellation = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let result = try await Task.detached(priority: .utility) {
                    try MediaPreviewDisplay.renderImage(data, type: type, cancellation: cancellation, worker: worker)
                }.value
                try Task.checkCancellation()
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
    private var generation = UUID()
    private let decode: Decoder
    private let write: @MainActor (Data, String) -> Bool

    init(decode: @escaping Decoder = { try await AskArtifactPresentation.image($0, mediaType: $1) },
         write: @escaping @MainActor (Data, String) -> Bool = { writeImage($0, mediaType: $1) }) {
        self.decode = decode; self.write = write
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

    func cancel() {
        generation = UUID(); image = nil; error = nil; busy = false
    }

    private func perform(_ ref: AskArtifactRef, access: AskArtifactAccess, copying: Bool) async {
        let current = UUID(); generation = current
        busy = true; error = nil
        if !copying { image = nil }
        defer { if generation == current { busy = false } }
        do {
            try Task.checkCancellation()
            try access.validate(ref)
            let bundle = try access.load(ref)
            guard bundle.manifest.ref == ref, let data = bundle.files[bundle.manifest.entry],
                  MediaImageType(rawValue: ref.mediaType) != nil,
                  data.count <= AskArtifactStore.maximumFileBytes,
                  AskToolPolicy.digest(data) == ref.sha256 else { throw AskArtifactError.corrupt }
            let result = try await decode(data, ref.mediaType)
            try Task.checkCancellation()
            guard generation == current else { return }
            // Account, conversation, grant or expiry may have changed during decoding.
            try access.validate(ref)
            guard let pixels = result.images.first else { throw AskArtifactError.corrupt }
            if copying, !write(data, ref.mediaType) { throw AskArtifactError.unavailable }
            image = NSImage(cgImage: pixels, size: .zero)
        } catch {
            guard generation == current else { return }
            if Task.isCancelled || error is CancellationError { return }
            let failure = (error as? AskArtifactError) ?? .unavailable
            if failure == .denied || failure == .expired { image = nil }
            self.error = failure.localizedDescription
        }
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
