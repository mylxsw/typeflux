import AppKit

/// Original access and source identity belong to one presentation, never a file-path cache.
@MainActor final class ScreenRecordingToastModel: ObservableObject {
    typealias Decoder = @Sendable (URL) async throws -> CGImage
    @Published private(set) var url: URL?
    @Published private(set) var image: CGImage?
    @Published private(set) var fileBytes: Int64 = 0
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    private(set) var generation = UUID()
    private var source: ClipboardPlaybackSource?
    private let decode: Decoder
    private(set) var task: Task<Void, Never>?
    private(set) var actionTask: Task<Void, Never>?
    init(decode: @escaping Decoder = { try await ScreenRecordingPreviewMedia.thumbnail($0) }) { self.decode = decode }
    deinit { task?.cancel(); actionTask?.cancel() }

    func start(_ url: URL, thumbnail: CGImage?) {
        retire(); self.url = url
        let token = generation, decode = self.decode
        // Production supplied images already own the timeline provider's pixel lease.
        let supplied = thumbnail.flatMap { $0.width <= 200 && $0.height <= 120 ? $0 : nil }
        task = Task { [weak self] in
            do {
                let original = try await ScreenRecordingTimelineLoader.inspect(url)
                var image = supplied
                if image == nil { image = try? await decode(url) }
                let current = try await ScreenRecordingTimelineLoader.inspect(url)
                guard !Task.isCancelled, let self, generation == token else { return }
                guard original == current else { retire(); return }
                self.source = original; self.image = image; fileBytes = Int64(original.bytes); ready = true
            } catch { if let self, generation == token { retire() } }
        }
    }
    func retire() {
        generation = UUID(); task?.cancel(); actionTask?.cancel()
        url = nil; image = nil; source = nil; fileBytes = 0; ready = false; busy = false
    }
    func perform(generation token: UUID, _ action: @escaping @MainActor (URL) -> Void) {
        guard generation == token, !busy, ready, let source, let url else { return }
        busy = true
        actionTask = Task { [weak self] in
            defer { if let self, generation == token { busy = false } }
            do {
                let current = try await ScreenRecordingTimelineLoader.inspect(url)
                guard !Task.isCancelled, let self, generation == token else { return }
                guard current == source else { retire(); return }
                // No suspension between the original authorization check and the explicit action.
                action(url)
            } catch { if let self, generation == token { retire() } }
        }
    }
}

/// AppKit may retain the SwiftUI subtree after orderOut; invalidate it synchronously.
@MainActor final class ScreenRecordingToastPanel: NSPanel {
    var retire: (() -> Void)?
    override func orderOut(_ sender: Any?) { retire?(); super.orderOut(sender) }
    override func close() { retire?(); super.close() }
    override func miniaturize(_ sender: Any?) { retire?(); super.miniaturize(sender) }
}
